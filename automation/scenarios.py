"""Disposable acceptance scenarios beyond the sequential live lab runner.

Every scenario requires an explicit validation-* instance. Use a fresh instance
for each scenario; existing later-stage instances are deliberately not reset.
"""

import argparse
import json
import os
import re
from pathlib import Path
import subprocess
import time

from common import ROOT, WorkshopError, atomic_json, run
from verify import http


class Scenario:
    def __init__(self, args):
        self.args = args
        self.private = ROOT / ".secrets" / args.instance
        self.base = [
            "make",
            "RUNTIME=" + args.runtime,
            "INSTANCE=" + args.instance,
            "PORT_BASE=" + str(args.port_base),
            "VAULT_EDITION=" + args.edition,
        ]
        self.results = []

    def make(self, action, lab=None, *, success=True, repeat=False, overwrite=False):
        self.private.mkdir(parents=True, exist_ok=True, mode=0o700)
        log = (
            self.private
            / "scenarios"
            / f'{len(self.results):02}-{action}-{lab or "instance"}.log'
        )
        log.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        argv = (
            self.base
            + [action]
            + (["LAB=" + lab] if lab else [])
            + (["OVERWRITE=1"] if overwrite else [])
        )
        with log.open("w") as handle:
            os.chmod(log, 0o600)
            process = subprocess.run(
                argv,
                cwd=ROOT,
                stdin=subprocess.DEVNULL,
                stdout=handle,
                stderr=subprocess.STDOUT,
            )
        if (process.returncode == 0) != success:
            raise WorkshopError(
                "Unexpected scenario result; inspect its private log: " + str(log)
            )
        text = log.read_text()
        recap = next(
            (
                line
                for line in text.splitlines()
                if line.startswith("localhost ") and "changed=" in line
            ),
            "",
        )
        if repeat and "changed=0 " not in recap:
            raise WorkshopError("Repeat changed configuration; inspect " + str(log))
        self.results.append(
            dict(action=action, lab=lab, expected_success=success, recap=recap)
        )
        atomic_json(self.private / "scenario-results.json", self.results)
        print(f"{action} {lab or self.args.instance}: expected result", flush=True)

    def config(self):
        return json.loads((self.private / "run.json").read_text())

    def compose(self, *args):
        c = self.config()
        return run(
            c["zt_compose"]
            + ["-f", str(self.private / "compose.yml"), "-p", c["zt_project"], *args],
            capture=True,
        )

    def vault(self, path, body=None):
        root = json.loads((self.private / "init.json").read_text())["root_token"]
        code, result = http(
            "http://127.0.0.1:" + str(self.args.port_base + 20),
            "/v1/" + path,
            "GET" if body is None else "POST",
            body,
            root,
            True,
        )
        if code not in [200, 204]:
            raise WorkshopError("Scenario Vault request failed: " + path)
        return result

    def wait_backend(self):
        for _ in range(60):
            try:
                code, _ = http(
                    "http://127.0.0.1:" + str(self.args.port_base), "/health"
                )
                if code == 200:
                    return
            except WorkshopError:
                pass
            time.sleep(1)
        raise WorkshopError("Scenario backend did not become healthy")

    def baseline(self):
        self.make("resolve", "01")
        self.make("resolve", "01", repeat=True)
        self.make("prepare", "02")
        learner = Path(self.config()["zt_build"]) / "backend/connector.js"
        manual = (
            ROOT / "data/connector.env.js"
        ).read_text() + "\n// Equivalent manual environment exercise.\n"
        learner.write_text(manual)
        self.compose("restart", "backend")
        self.wait_backend()
        self.make("verify", "02")
        self.make("prepare", "03")
        if learner.read_text() != manual:
            raise WorkshopError("Prepare replaced a manual previous solution")
        if (self.private / "init.json").exists() or self.compose(
            "ps", "-a", "-q", "vault"
        ).strip():
            raise WorkshopError("Baseline preparation eagerly started Vault")
        self.make("resolve", "02", overwrite=True)
        self.make("resolve", "02", repeat=True)

    def manual(self):
        self.make("resolve", "03")
        self.make("prepare", "04")
        self.make("prepare", "04")
        if "approle/" not in self.vault("sys/auth"):
            self.vault("sys/auth/approle", {"type": "approle"})
        from jinja2 import Environment, FileSystemLoader

        policy = (
            Environment(loader=FileSystemLoader(ROOT / "terraform/workshop/policies"))
            .get_template("app.hcl")
            .render(dynamic=False)
        )
        # HCL template directives are Terraform syntax, not Jinja. At this stage
        # the only conditional block is the database credential permission.
        before, after = policy.split("%{ if dynamic ~}", 1)
        _, suffix = after.split("%{ endif ~}", 1)
        policy = before + suffix
        self.vault("sys/policies/acl/app-policy", {"policy": policy})
        self.vault(
            "auth/approle/role/zero-trust-app",
            dict(
                token_policies=["app-policy"],
                token_ttl=3600,
                token_max_ttl=14400,
                secret_id_ttl=86400,
                secret_id_num_uses=0,
            ),
        )
        role = self.vault("auth/approle/role/zero-trust-app/role-id")["data"]["role_id"]
        secret = self.vault("auth/approle/role/zero-trust-app/secret-id", {})["data"][
            "secret_id"
        ]
        file = self.private / "backend.env"
        values = {"VAULT_ROLE_ID": role, "VAULT_SECRET_ID": secret}
        lines = [
            line.split("=", 1) for line in file.read_text().splitlines() if "=" in line
        ]
        file.write_text(
            "\n".join(key + "=" + values.get(key, value) for key, value in lines) + "\n"
        )
        learner = Path(self.config()["zt_build"]) / "backend/connector.js"
        learner.write_text(
            (ROOT / "data/connector.lab-approle.js").read_text()
            + "\n// Equivalent manual AppRole solution.\n"
        )
        self.compose("up", "-d", "--no-deps", "--force-recreate", "backend")
        self.wait_backend()
        self.make("verify", "04")
        self.make("resolve", "04", success=False)
        self.make("adopt", "04")
        self.make("resolve", "04", overwrite=True)
        self.make("resolve", "04", repeat=True)
        self.compose("restart", "vault")
        self.make("unseal")
        self.make("verify", "04")

    def recovery(self):
        self.make("resolve", "04")
        before = json.loads((self.private / "runtime.json").read_text())
        import psycopg

        def counts():
            with psycopg.connect(
                host="127.0.0.1",
                port=self.args.port_base + 32,
                dbname="appdb",
                user="appuser",
                password="apppassword",
            ) as db:
                with db.cursor() as cursor:
                    cursor.execute(
                        "SELECT (SELECT count(*) FROM users), (SELECT count(*) FROM orders)"
                    )
                    return cursor.fetchone()

        old_counts = counts()
        token = json.loads((self.private / "tokens/ansible").read_text())["token"]
        code, _ = http(
            "http://127.0.0.1:" + str(self.args.port_base + 20),
            "/v1/auth/token/revoke-self",
            "POST",
            {},
            token,
            True,
        )
        if code not in [200, 204]:
            raise WorkshopError("Could not revoke the scenario automation token")
        self.make("resolve", "04")
        if (
            before["secret_id"]
            != json.loads((self.private / "runtime.json").read_text())["secret_id"]
            or counts() != old_counts
        ):
            raise WorkshopError(
                "Credential repair changed application identity or row counts"
            )
        self.make("resolve", "04", repeat=True)
        self.make("resolve", "03", success=False)
        self.make("reset", success=False)
        original = self.private / "init.json"
        backup = self.private / "init.recovery-check.json"
        if backup.exists():
            raise WorkshopError(
                "Recovery test backup already exists; refusing to overwrite it"
            )
        original.rename(backup)
        try:
            self.make("unseal", success=False)
        finally:
            backup.rename(original)
        self.make("verify", "04")

    def drift_jump(self):
        self.make("resolve", "04")
        current = self.vault("sys/policies/acl/app-policy")["data"]["policy"]
        self.vault(
            "sys/policies/acl/app-policy",
            {
                "policy": current
                + '\npath "secret/data/zt-drift-probe" { capabilities = ["deny"] }\n'
            },
        )
        try:
            self.make("drift", "04", success=False)
            self.make("resolve", "04")
        finally:
            self.vault("sys/policies/acl/app-policy", {"policy": current})
        self.make("drift", "04")
        self.make("resolve", "10")
        self.make("resolve", "10", repeat=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "scenario", choices=["baseline", "manual", "recovery", "drift-jump"]
    )
    parser.add_argument("--runtime", choices=["docker", "podman"], required=True)
    parser.add_argument("--instance", required=True)
    parser.add_argument("--port-base", type=int, required=True)
    parser.add_argument(
        "--edition", choices=["enterprise", "community"], default="enterprise"
    )
    args = parser.parse_args()
    if not 1024 <= args.port_base <= 64000:
        parser.error("port-base must be 1024–64000")
    if not re.fullmatch(r"validation-[a-z0-9-]{1,14}", args.instance):
        parser.error(
            "Use a fresh validation-* instance; scenarios never reset existing storage"
        )
    scenario = Scenario(args)
    getattr(scenario, args.scenario.replace("-", "_"))()


if __name__ == "__main__":
    try:
        main()
    except (WorkshopError, AssertionError) as exc:
        raise SystemExit(str(exc))
