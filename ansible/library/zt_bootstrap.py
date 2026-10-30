#!/usr/bin/python
"""Initialize/unseal and reconcile scoped identities with private custody."""

import json
import os
from pathlib import Path
import time
from ansible.module_utils.basic import AnsibleModule
from ansible.module_utils.zt_http import request, save

TF_POLICY = """path "sys/mounts" { capabilities = ["read"] }
path "sys/mounts/secret" { capabilities = ["create","read","update","sudo"] }
path "sys/mounts/secret/tune" { capabilities = ["read"] }
path "sys/mounts/database" { capabilities = ["create","read","update","sudo"] }
path "sys/mounts/database/tune" { capabilities = ["read"] }
path "sys/auth" { capabilities = ["read"] }
path "sys/mounts/auth/approle" { capabilities = ["read"] }
path "sys/mounts/auth/approle/tune" { capabilities = ["read"] }
path "sys/mounts/auth/jwt" { capabilities = ["read"] }
path "sys/mounts/auth/jwt/tune" { capabilities = ["read"] }
path "sys/auth/approle" { capabilities = ["create","read","update","sudo"] }
path "sys/auth/approle/tune" { capabilities = ["read"] }
path "sys/auth/jwt" { capabilities = ["create","read","update","sudo"] }
path "sys/auth/jwt/tune" { capabilities = ["read"] }
path "auth/token/create" { capabilities = ["update"] }
path "sys/policies/acl/app-policy" { capabilities = ["create","read","update"] }
path "sys/policies/acl/zero-trust-jwt-lab" { capabilities = ["create","read","update"] }
path "sys/policies/acl/zt-static" { capabilities = ["create","read","update"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "sys/capabilities-self" { capabilities = ["update"] }
"""
ANSIBLE_POLICY = """path "auth/token/create/zt-static" { capabilities = ["update"] }
path "secret/data/postgres" { capabilities = ["create","read","update"] }
path "database/config/postgres" { capabilities = ["create","read","update"] }
path "database/roles/*" { capabilities = ["create","read","update"] }
path "database/creds/*" { capabilities = ["read"] }
path "auth/approle/role/zero-trust-app" { capabilities = ["create","read","update"] }
path "auth/approle/role/zero-trust-app/*" { capabilities = ["create","read","update"] }
path "auth/approle/login" { capabilities = ["update"] }
path "auth/jwt/config" { capabilities = ["create","read","update"] }
path "auth/jwt/role/zero-trust-jwt-lab" { capabilities = ["create","read","update"] }
path "sys/leases/lookup" { capabilities = ["update"] }
path "sys/leases/revoke" { capabilities = ["update"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "sys/capabilities-self" { capabilities = ["update"] }
"""


def main():
    m = AnsibleModule(
        argument_spec=dict(
            address=dict(required=True),
            private=dict(required=True),
            unseal_only=dict(type="bool", default=False),
        ),
        supports_check_mode=True,
    )
    base = m.params["address"]
    private = Path(m.params["private"])
    init = private / "init.json"
    if m.check_mode:
        m.exit_json(
            changed=False,
            skipped=True,
            msg="Bootstrap requires live operation; check mode does not establish custody",
        )
    changed = False
    try:
        for _ in range(60):
            try:
                code, health = request(base, "v1/sys/seal-status")
                if code == 200:
                    break
            except OSError:
                pass
            time.sleep(2)
        else:
            m.fail_json(msg="Vault did not become reachable")
        if not health.get("initialized"):
            if m.params["unseal_only"]:
                m.fail_json(
                    msg="Instance is not initialized; unseal will not initialize it"
                )
            if init.exists():
                m.fail_json(
                    msg="Recovery material exists but Vault is fresh; refusing to replace custody. Select the correct instance."
                )
            code, material = request(
                base, "v1/sys/init", "PUT", {"secret_shares": 1, "secret_threshold": 1}
            )
            if code != 200:
                m.fail_json(
                    msg="Vault initialization failed; inspect live initialization state before retrying"
                )
            save(init, material)
            changed = True
        if not init.exists():
            m.fail_json(
                msg="Initialized Vault has no automation recovery file. Supply recovery material through the documented explicit recovery path; it will not be reinitialized."
            )
        material = json.loads(init.read_text())
        code, health = request(base, "v1/sys/seal-status")
        if health.get("sealed"):
            for key in material.get("keys_base64", []):
                code, health = request(base, "v1/sys/unseal", "PUT", {"key": key})
                if code != 200:
                    m.fail_json(
                        msg="Unseal failed; recovery material may belong to a different instance"
                    )
                if not health.get("sealed"):
                    break
            if health.get("sealed"):
                m.fail_json(
                    msg="Vault remains sealed; provide sufficient recovery shares"
                )
            changed = True
        if m.params["unseal_only"]:
            m.exit_json(changed=changed)
        root = material.get("root_token")
        static_role = {
            "allowed_policies": ["zt-static"],
            "orphan": True,
            "renewable": True,
            "token_explicit_max_ttl": 86400,
        }
        code, data = request(base, "v1/auth/token/roles/zt-static", token=root)
        if code != 200 or not all(
            data.get("data", {}).get(k) == v for k, v in static_role.items()
        ):
            code, _ = request(
                base, "v1/auth/token/roles/zt-static", "POST", static_role, root
            )
            if code not in [200, 204]:
                m.fail_json(
                    msg="Cannot establish constrained static application token role"
                )
            changed = True
        for name, policy in [("terraform", TF_POLICY), ("ansible", ANSIBLE_POLICY)]:
            policy_name = "zt-bootstrap-" + name
            code, data = request(base, "v1/sys/policies/acl/" + policy_name, token=root)
            if code != 200 or data.get("data", {}).get("policy") != policy:
                code, _ = request(
                    base,
                    "v1/sys/policies/acl/" + policy_name,
                    "PUT",
                    {"policy": policy},
                    root,
                )
                if code not in [200, 204]:
                    m.fail_json(
                        msg="Bootstrap root identity cannot repair scoped policy; use explicit recovery"
                    )
                changed = True
            token_file = private / "tokens" / name
            token = (
                json.loads(token_file.read_text()).get("token")
                if token_file.exists()
                else None
            )
            code, data = (
                request(base, "v1/auth/token/lookup-self", token=token)
                if token
                else (403, {})
            )
            if (
                code != 200
                or data.get("data", {}).get("ttl", 0) < 300
                or policy_name not in data.get("data", {}).get("policies", [])
            ):
                code, data = request(
                    base,
                    "v1/auth/token/create",
                    "POST",
                    {
                        "policies": [policy_name],
                        "ttl": "24h",
                        "renewable": True,
                        "no_default_policy": False,
                    },
                    root,
                )
                if code != 200:
                    m.fail_json(
                        msg="Cannot issue scoped automation credential; root recovery may be required"
                    )
                token = data["auth"]["client_token"]
                save(token_file, {"token": token})
                changed = True
            code, caps = request(
                base,
                "v1/sys/capabilities-self",
                "POST",
                {
                    "paths": [
                        "sys/init",
                        "sys/policies/acl/zt-bootstrap-terraform",
                        "auth/token/lookup-self",
                    ]
                },
                token,
            )
            if (
                code != 200
                or caps.get("sys/init") != ["deny"]
                or caps.get("sys/policies/acl/zt-bootstrap-terraform") != ["deny"]
                or "read" not in caps.get("auth/token/lookup-self", [])
            ):
                m.fail_json(msg="Automation identity capability boundary failed")
        m.exit_json(changed=changed)
    except (OSError, ValueError, KeyError):
        m.fail_json(
            msg="Bootstrap could not complete; inspect connectivity and private recovery file (no secret data logged)"
        )


if __name__ == "__main__":
    main()
