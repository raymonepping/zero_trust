"""Behavioral grading. No apply, seed, configuration repair or source replacement."""

import json
from datetime import datetime, timezone
from pathlib import Path
import time
import urllib.request
import urllib.error
import uuid
from common import ROOT, WorkshopError, atomic_json, run


def http(base, path, method="GET", body=None, token=None, vault=False):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["X-Vault-Token" if vault else "Authorization"] = (
            token if vault else "Bearer " + token
        )
    req = urllib.request.Request(
        base + path,
        data=None if body is None else json.dumps(body).encode(),
        headers=headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        return e.code, {}  # Never include response bodies in failure diagnostics.
    except OSError:
        raise WorkshopError("Verification endpoint is unreachable") from None


def expect(value, message):
    if not value:
        raise WorkshopError(message)


def status(c):
    build = Path(c["zt_build"])
    record = build / "last-attempt.json"
    attempt = json.loads(record.read_text()) if record.exists() else None
    result = {
        "requested_lab": attempt.get("lab") if attempt else None,
        "last_attempt": attempt,
        "last_verification": None,
        "observed": {"reachable": False},
    }
    evidence = build / "verification.json"
    if evidence.exists():
        e = json.loads(evidence.read_text())
        e["current_inputs"] = (
            e.get("digest") == c["zt_digest"] and e.get("runtime") == c["zt_target"]
        )
        result["last_verification"] = e
    try:
        code, health = http("http://127.0.0.1:" + str(c["zt_port_base"]), "/health")
        code2, creds = http(
            "http://127.0.0.1:" + str(c["zt_port_base"]), "/credentials"
        )
        result["observed"] = {
            "reachable": True,
            "healthy": code == 200,
            "credential_source": creds.get("source") if code2 == 200 else None,
        }
    except WorkshopError:
        pass
    return result


def login(base, username):
    # The tracked LDAP demo fixture defines different passwords for some users.
    # These are workshop inputs, never values copied from a private .env.
    password = None
    for entry in (ROOT / "ldap/bootstrap.ldif").read_text().split("\n\n"):
        fields = dict(
            line.split(": ", 1)
            for line in entry.splitlines()
            if ": " in line and not line.startswith("#")
        )
        if fields.get("uid") == username:
            password = fields.get("userPassword")
    expect(
        password is not None,
        "No public fixture credential defined for the verification user",
    )
    code, data = http(
        base, "/auth/token", "POST", {"username": username, "password": password}
    )
    expect(
        code == 200 and data.get("access_token"),
        f"Fixture user login failed: {username}",
    )
    return data["access_token"]


def verify(c):
    lab = next(x for x in c["zt_manifest"]["labs"] if x["id"] == c["zt_lab"])
    level = int(lab["id"])
    base = "http://127.0.0.1:" + str(c["zt_port_base"])
    vault = "http://127.0.0.1:" + str(c["zt_port_base"] + 20)
    private = Path(c["zt_private"])
    build = Path(c["zt_build"])
    probes = []
    evidence = {
        "lab": lab["id"],
        "digest": c["zt_digest"],
        "runtime": c["zt_target"],
        "revision": c.get("zt_revision"),
        "at": datetime.now(timezone.utc).isoformat(),
        "result": "failed",
        "probes": probes,
    }
    # Invalidate any older success before probing.
    atomic_json(build / "verification.json", evidence)
    code, health = http(base, "/health")
    expect(
        code == 200 and health.get("db") == "connected",
        "Application has no working database connection",
    )
    probes.append("health")
    code, creds = http(base, "/credentials")
    expect(
        code == 200 and creds.get("source") == lab["source"],
        "Credential strategy does not match the lab outcome",
    )
    probes.append("credentials")
    code, users = http(base, "/users")
    expect(
        code == 200 and isinstance(users, list) and users,
        "Application user query failed or fixtures absent",
    )
    probes.append("users")
    automation = (
        json.loads((private / "tokens/ansible").read_text())["token"]
        if level >= 3 and (private / "tokens/ansible").exists()
        else None
    )
    runtime = (
        json.loads((private / "runtime.json").read_text())
        if level >= 3 and (private / "runtime.json").exists()
        else {}
    )
    env_path = private / "backend.env"
    if env_path.exists():
        runtime_env = dict(
            line.split("=", 1)
            for line in env_path.read_text().splitlines()
            if "=" in line and not line.startswith("#")
        )
        runtime["role_id"] = runtime_env.get("VAULT_ROLE_ID", runtime.get("role_id"))
        runtime["secret_id"] = runtime_env.get(
            "VAULT_SECRET_ID", runtime.get("secret_id")
        )
    leases = []
    tokens = []

    def v(path, method="GET", body=None, token=None):
        return http(vault, "/v1/" + path, method, body, token or automation, True)

    def issue(role):
        code, result = v("database/creds/" + role)
        expect(
            code == 200 and result.get("lease_id"), "Dynamic credential issuance failed"
        )
        leases.append(result["lease_id"])
        return result["data"]

    try:
        if "scope" in lab["probes"]:
            code, data = v(
                "auth/approle/login",
                "POST",
                {
                    "role_id": runtime.get("role_id"),
                    "secret_id": runtime.get("secret_id"),
                },
            )
            expect(code == 200, "AppRole cannot authenticate")
            token = data["auth"]["client_token"]
            tokens.append(token)
            code, caps = v(
                "sys/capabilities-self",
                "POST",
                {
                    "paths": [
                        "secret/data/postgres",
                        "sys/mounts",
                        "sys/policies/acl/zt-bootstrap-terraform",
                    ]
                },
                token,
            )
            expect(
                code == 200
                and "read" in caps.get("secret/data/postgres", [])
                and caps.get("sys/mounts") == ["deny"]
                and caps.get("sys/policies/acl/zt-bootstrap-terraform") == ["deny"],
                "AppRole permission boundary failed",
            )
            probes.append("scope")
        if "dynamic_login" in lab["probes"]:
            import psycopg

            role = "viewer-read" if level >= 9 else "app-role"
            credential = issue(role)
            with psycopg.connect(
                host="127.0.0.1",
                port=c["zt_port_base"] + 32,
                dbname="appdb",
                user=credential["username"],
                password=credential["password"],
                connect_timeout=5,
            ) as db:
                with db.cursor() as cursor:
                    cursor.execute("SELECT count(*) FROM users")
                    expect(
                        cursor.fetchone()[0] > 0, "Dynamic DB login cannot query users"
                    )
            probes.append("dynamic_login")
        if "rotation" in lab["probes"]:
            first = creds.get("leaseId")
            deadline = time.monotonic() + 150
            expect(first, "Active connector provides no lease evidence")
            while time.monotonic() < deadline:
                time.sleep(3)
                code, current = http(base, "/credentials")
                expect(
                    code == 200, "Credential access failed during lifecycle observation"
                )
                code, _ = http(base, "/users")
                expect(code == 200, "DB access failed during credential lifecycle")
                if current.get("leaseId") and current["leaseId"] != first:
                    break
            else:
                raise WorkshopError(
                    "No proactive credential reissuance observed within 150 seconds"
                )
            probes.append("rotation")
        if "agent_file" in lab["probes"]:
            # Read only public metadata from the rendered file, never output its password.
            command = c["zt_compose"] + [
                "-f",
                str(private / "compose.yml"),
                "-p",
                c["zt_project"],
                "exec",
                "-T",
                "backend",
                "node",
                "-e",
                "const fs=require('fs'); const d=JSON.parse(fs.readFileSync(process.env.VAULT_AGENT_CREDS_FILE));process.stdout.write(JSON.stringify({lease:d.lease_id,user:d.username}))",
            ]
            observed = json.loads(run(command, capture=True))
            expect(
                observed.get("lease") == creds.get("leaseId"),
                "Backend credential metadata differs from Agent file",
            )
            probes.append("agent_file")
        if "jwt_rejection" in lab["probes"]:
            code, _ = v(
                "auth/jwt/login",
                "POST",
                {"role": "zero-trust-jwt-lab", "jwt": "invalid.jwt.signature"},
            )
            expect(
                code == 400,
                "Vault did not reject the invalid JWT for the expected validation reason",
            )
            code, _ = http(base, "/ciba/pending", token="invalid.jwt.signature")
            expect(code == 401, "Protected backend endpoint did not reject invalid JWT")
            code, _ = http(
                base,
                "/auth/token",
                "POST",
                {"username": "alice", "password": "incorrect-password"},
            )
            expect(
                code == 401, "Identity provider did not reject an incorrect password"
            )
            probes.append("jwt_rejection")
        if "role_isolation" in lab["probes"]:
            with psycopg.connect(
                host="127.0.0.1",
                port=c["zt_port_base"] + 32,
                dbname="appdb",
                user="appuser",
                password="apppassword",
                connect_timeout=5,
            ) as reference_db:
                with reference_db.cursor() as cursor:
                    cursor.execute(
                        "SELECT classification, count(*) FROM orders GROUP BY classification"
                    )
                    reference_counts = dict(cursor.fetchall())
            for username, role, allowed in [
                ("alice", "viewer-read", {"public"}),
                ("cojan", "support-read", {"public", "internal"}),
                (
                    "repping",
                    "admin-read",
                    {"public", "internal", "confidential", "restricted"},
                ),
            ]:
                user_token = login(base, username)
                code, data = http(base, "/credentials", token=user_token)
                expect(
                    code == 200 and data.get("vaultRole") == role,
                    "Authenticated caller mapped to the wrong database role",
                )
                code, orders = http(base, "/orders", token=user_token)
                expect(
                    code == 200 and isinstance(orders, list),
                    "Role-scoped orders query failed",
                )
                expect(
                    all(x["classification"] in allowed for x in orders),
                    "Application role filtering exposed unauthorized classifications",
                )
                expect(
                    set(data.get("allowed_classifications", [])) == allowed,
                    "Reported data access differs from the caller's role",
                )
                for path in ["/preferences", "/training", "/tickets", "/projects"]:
                    code, rows = http(base, path, token=user_token)
                    expect(
                        code == 200
                        and all(x["classification"] in allowed for x in rows),
                        "Application exposed classifications beyond the caller's role",
                    )
                cred = issue(role)
                with psycopg.connect(
                    host="127.0.0.1",
                    port=c["zt_port_base"] + 32,
                    dbname="appdb",
                    user=cred["username"],
                    password=cred["password"],
                    connect_timeout=5,
                ) as db:
                    with db.cursor() as cursor:
                        cursor.execute("SELECT DISTINCT classification FROM orders")
                        classes = {x[0] for x in cursor.fetchall()}
                        expect(
                            classes == (set(reference_counts) & allowed),
                            "RLS did not expose exactly the allowed classifications",
                        )
                        cursor.execute("SELECT count(*) FROM orders")
                        expect(
                            cursor.fetchone()[0]
                            == sum(
                                count
                                for classification, count in reference_counts.items()
                                if classification in allowed
                            ),
                            "RLS allowed/denied row counts do not match the expected role",
                        )
                        if role == "viewer-read":
                            try:
                                cursor.execute("SELECT count(*) FROM projects")
                            except psycopg.errors.InsufficientPrivilege:
                                db.rollback()
                            else:
                                raise WorkshopError(
                                    "Viewer unexpectedly has access to projects"
                                )
                        try:
                            cursor.execute("UPDATE users SET city=city WHERE false")
                        except psycopg.errors.InsufficientPrivilege:
                            db.rollback()
                        else:
                            raise WorkshopError(
                                "Read-scoped identity unexpectedly has write access"
                            )
            probes.append("role_isolation")
        if "ciba" in lab["probes"]:
            ciba_probe(c, base)
            probes.append("ciba")
    finally:
        for lease in leases:
            code, _ = v("sys/leases/revoke", "POST", {"lease_id": lease})
            if code not in [200, 204]:
                raise WorkshopError("Probe lease cleanup failed")
        for token in tokens:
            code, _ = v("auth/token/revoke-self", "POST", {}, token)
            expect(code in [200, 204], "Probe login token cleanup failed")
    expect(
        set(probes) == set(lab["probes"]),
        "Some required behavioral probes did not execute",
    )
    evidence["result"] = "passed"
    atomic_json(build / "verification.json", evidence)
    print("Behavioral probes passed: " + ", ".join(probes))


def ciba_probe(c, base):
    import psycopg

    token = login(base, "cojan")
    connection = psycopg.connect(
        host="127.0.0.1",
        port=c["zt_port_base"] + 32,
        dbname="appdb",
        user="appuser",
        password="apppassword",
        autocommit=True,
    )
    marker = "zt-probe-" + uuid.uuid4().hex
    with connection.cursor() as cur:
        cur.execute(
            "INSERT INTO orders (user_id,item,classification,status) SELECT id,%s,'public','pending' FROM users ORDER BY id LIMIT 1 RETURNING id",
            (marker,),
        )
        order_id = cur.fetchone()[0]
    try:
        for decision, expected in [("CANCELLED", "denied"), ("SUCCEED", "approved")]:
            code, session = http(
                base,
                "/ciba/initiate",
                "POST",
                {"orderId": order_id, "newStatus": "processing"},
                token,
            )
            expect(code == 200 and session.get("sessionId"), "CIBA initiation failed")
            write = {"newStatus": "processing", "cibaSessionId": session["sessionId"]}
            code, _ = http(
                base, f"/ciba/orders/{order_id}/status", "POST", write, token
            )
            expect(code == 403, "Unapproved CIBA session was not denied")
            for _ in range(30):
                code, pending = http(base, "/ciba/pending", token=token)
                matches = (
                    [
                        x
                        for x in pending
                        if x.get("bindingMessage")
                        == f"order-{order_id}-status-processing"
                    ]
                    if code == 200
                    else []
                )
                if matches:
                    break
                time.sleep(1)
            else:
                raise WorkshopError("CIBA approval delegation never arrived")
            code, _ = http(
                base,
                "/ciba/approve",
                "POST",
                {"requestId": matches[0]["id"], "decision": decision},
                token,
            )
            expect(code == 200, "CIBA approval callback failed")
            for _ in range(45):
                code, state = http(
                    base, "/ciba/status/" + session["sessionId"], token=token
                )
                if state.get("status") in ["approved", "denied", "expired"]:
                    break
                time.sleep(1)
            expect(
                state.get("status") == expected,
                "CIBA did not reach the expected final state",
            )
            code, _ = http(
                base, f"/ciba/orders/{order_id}/status", "POST", write, token
            )
            expect(
                code == (200 if decision == "SUCCEED" else 403),
                "CIBA gated write result is incorrect",
            )
        with connection.cursor() as cur:
            cur.execute("SELECT status FROM orders WHERE id=%s", (order_id,))
            expect(
                cur.fetchone()[0] == "processing",
                "Approved write did not reach PostgreSQL",
            )
    finally:
        with connection.cursor() as cur:
            cur.execute(
                "DELETE FROM orders WHERE id=%s AND item=%s", (order_id, marker)
            )
        connection.close()
