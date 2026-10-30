#!/usr/bin/python
"""Validate private runtime identities before replacing expired material."""

import json
from pathlib import Path
from ansible.module_utils.basic import AnsibleModule
from ansible.module_utils.zt_http import request, save


def main():
    m = AnsibleModule(
        argument_spec=dict(
            address=dict(required=True),
            private=dict(required=True),
            features=dict(type="list", elements="str", required=True),
        ),
        supports_check_mode=True,
    )
    if m.check_mode:
        m.exit_json(
            changed=False, skipped=True, msg="Credential validity requires live probes"
        )
    p = m.params
    private = Path(p["private"])
    base = p["address"]
    changed = False
    try:
        automation = json.loads((private / "tokens/ansible").read_text())["token"]
        runtime_file = private / "runtime.json"
        material = json.loads(runtime_file.read_text()) if runtime_file.exists() else {}
        env_file = private / "backend.env"
        if "approle" in p["features"] and env_file.exists():
            values = dict(
                line.split("=", 1)
                for line in env_file.read_text().splitlines()
                if "=" in line and not line.startswith("#")
            )
            if values.get("VAULT_ROLE_ID") and values.get("VAULT_SECRET_ID"):
                delivered = {
                    "role_id": values["VAULT_ROLE_ID"],
                    "secret_id": values["VAULT_SECRET_ID"],
                }
                if any(material.get(k) != v for k, v in delivered.items()):
                    material.update(delivered)
                    changed = True
        if "approle" not in p["features"]:
            code, result = (
                request(base, "v1/auth/token/lookup-self", token=material.get("token"))
                if material.get("token")
                else (403, {})
            )
            if code != 200 or result.get("data", {}).get("ttl", 0) < 300:
                code, result = request(
                    base,
                    "v1/auth/token/create/zt-static",
                    "POST",
                    {"policies": ["zt-static"], "ttl": "24h"},
                    automation,
                )
                if code != 200:
                    m.fail_json(msg="Cannot issue application static KV token")
                material["token"] = result["auth"]["client_token"]
                changed = True
        elif "approle" in p["features"]:
            code, result = request(
                base, "v1/auth/approle/role/zero-trust-app/role-id", token=automation
            )
            if code != 200:
                m.fail_json(msg="Cannot read application role ID")
            role_id = result["data"]["role_id"]
            code, login = request(
                base,
                "v1/auth/approle/login",
                "POST",
                {"role_id": role_id, "secret_id": material.get("secret_id", "")},
            )
            if code != 200:
                code, result = request(
                    base,
                    "v1/auth/approle/role/zero-trust-app/secret-id",
                    "POST",
                    {},
                    automation,
                )
                if code != 200:
                    m.fail_json(msg="Cannot issue application secret ID")
                material.update(role_id=role_id, secret_id=result["data"]["secret_id"])
                changed = True
                code, login = request(
                    base,
                    "v1/auth/approle/login",
                    "POST",
                    {"role_id": role_id, "secret_id": material["secret_id"]},
                )
                if code != 200:
                    m.fail_json(msg="Fresh AppRole identity cannot log in")
            if material.get("role_id") != role_id:
                material["role_id"] = role_id
                changed = True
            request(
                base,
                "v1/auth/token/revoke-self",
                "POST",
                {},
                login["auth"]["client_token"],
            )
        if changed or not runtime_file.exists():
            save(runtime_file, material)
        m.exit_json(changed=changed)
    except (OSError, ValueError, KeyError):
        m.fail_json(msg="Runtime identity validation failed")


if __name__ == "__main__":
    main()
