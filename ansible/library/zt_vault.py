#!/usr/bin/python
"""Compare an operational Vault object before writing; never own mounts/policies."""

import hashlib
import json
import re
from pathlib import Path
from ansible.module_utils.basic import AnsibleModule
from ansible.module_utils.zt_http import request, save, subset


def canonical_sql(statement):
    # Preserve quoted strings/identifiers; normalize only token-separating space.
    pattern = r"'(?:(?:'')|[^'])*'|\"(?:(?:\"\")|[^\"])*\"|\s+"
    return re.sub(
        pattern,
        lambda match: match.group(0) if match.group(0)[0] in ["'", '"'] else " ",
        statement,
    ).strip()


def main():
    m = AnsibleModule(
        argument_spec=dict(
            address=dict(required=True),
            private=dict(required=True),
            path=dict(required=True),
            desired=dict(type="dict", required=True, no_log=True),
            kind=dict(choices=["plain", "kv", "database"], default="plain"),
        ),
        supports_check_mode=True,
    )
    p = m.params
    private = Path(p["private"])
    path = p["path"]
    desired = p["desired"]
    if not path.startswith(
        (
            "secret/data/",
            "database/config/",
            "database/roles/",
            "auth/approle/role/",
            "auth/jwt/config",
            "auth/jwt/role/",
        )
    ):
        m.fail_json(msg="Operational module refuses structural API path")
    try:
        token = json.loads((private / "tokens/ansible").read_text())["token"]
        code, current = request(p["address"], "v1/" + path, token=token)
        if code not in [200, 404]:
            m.fail_json(msg="Vault configuration read failed", status=code)
        actual = current.get("data", {})
        visible = dict(desired)
        if p["kind"] == "kv":
            actual = actual.get("data", {})
        if p["kind"] == "database":
            visible = {
                k: v
                for k, v in desired.items()
                if k not in ["password", "verify_connection"]
            }
            actual = {**actual, **actual.get("connection_details", {})}
        receipt = private / "receipts" / hashlib.sha256(path.encode()).hexdigest()
        wanted = hashlib.sha256(
            json.dumps(desired, sort_keys=True).encode()
        ).hexdigest()
        sql_equal = True
        if path.startswith("database/roles/"):
            for field in ["creation_statements", "revocation_statements"]:
                if field in visible:
                    sql_equal = sql_equal and [
                        canonical_sql(x) for x in actual.get(field, [])
                    ] == [canonical_sql(x) for x in visible.pop(field)]
        opaque_ok = p["kind"] != "database" or (
            receipt.exists() and json.loads(receipt.read_text()).get("digest") == wanted
        )
        changed = (
            code != 200 or not subset(actual, visible) or not opaque_ok or not sql_equal
        )
        if changed and not m.check_mode:
            body = desired
            if p["kind"] == "kv":
                body = {
                    "data": desired,
                    "options": {
                        "cas": current.get("data", {})
                        .get("metadata", {})
                        .get("version", 0)
                    },
                }
            code, _ = request(p["address"], "v1/" + path, "POST", body, token)
            if code not in [200, 204]:
                m.fail_json(msg="Vault configuration write failed", status=code)
            if p["kind"] == "database":
                save(receipt, {"digest": wanted})
        m.exit_json(changed=changed)
    except (OSError, ValueError, KeyError):
        m.fail_json(
            msg="Operational Vault reconciliation failed; check scoped identity and connectivity"
        )


if __name__ == "__main__":
    main()
