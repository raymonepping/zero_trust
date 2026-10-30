#!/usr/bin/python
"""LDAP command adapter: read each DN before adding, never bulk reimport."""

from pathlib import Path
import subprocess
import base64
import os
import time
from ansible.module_utils.basic import AnsibleModule


def main():
    m = AnsibleModule(
        argument_spec=dict(
            runtime=dict(required=True),
            compose=dict(type="list", elements="str", required=True),
            file=dict(required=True),
            project=dict(required=True),
            ldif=dict(required=True),
        ),
        supports_check_mode=True,
    )
    for key in ["COMPOSE_FILE", "COMPOSE_PROFILES", "COMPOSE_PROJECT_NAME"]:
        os.environ.pop(key, None)
    p = m.params
    base = p["compose"] + [
        "-f",
        p["file"],
        "-p",
        p["project"],
        "exec",
        "-T",
        "openldap",
    ]
    args = [
        "-x",
        "-H",
        "ldap://localhost:389",
        "-D",
        "cn=admin,dc=my,dc=org",
        "-w",
        "admin",
    ]

    def cmd(command, body=None):
        return subprocess.run(
            base + command, input=body, text=True, capture_output=True, timeout=30
        )

    def attributes(lines):
        result = {}
        for line in lines:
            if not line or line.startswith("#") or ":" not in line:
                continue
            key, value = line.split(":", 1)
            if value.startswith(":"):
                value = base64.b64decode(value[1:].strip()).decode()
            else:
                value = value.strip()
            result.setdefault(key.lower(), []).append(value)
        return result

    changed = False
    for _ in range(50):
        ready = cmd(["ldapwhoami"] + args)
        if ready.returncode == 0:
            break
        time.sleep(2)
    else:
        m.fail_json(msg="LDAP bind did not become ready")
    for entry in Path(p["ldif"]).read_text().split("\n\n"):
        lines = [x for x in entry.splitlines() if x and not x.startswith("#")]
        if not lines:
            continue
        dn = next((x[4:] for x in lines if x.startswith("dn: ")), None)
        if not dn:
            m.fail_json(msg="Invalid LDIF entry")
        desired = attributes(lines)
        fields = [name for name in desired if name not in ["dn", "userpassword"]]
        result = cmd(
            ["ldapsearch", "-LLL", "-o", "ldif-wrap=no"]
            + args
            + ["-b", dn, "-s", "base", "(objectClass=*)"]
            + fields
        )
        if result.returncode not in [0, 32]:
            m.fail_json(msg="LDAP read failed")
        if result.returncode == 32:
            changed = True
            if not m.check_mode:
                if cmd(["ldapadd"] + args, "\n".join(lines) + "\n").returncode:
                    m.fail_json(msg="LDAP entry creation failed")
        else:
            actual = attributes(result.stdout.splitlines())
            modifications = []
            for name in fields:
                expected = desired[name]
                if name == "objectclass":
                    same = {v.lower() for v in expected} <= {
                        v.lower() for v in actual.get(name, [])
                    }
                else:
                    same = sorted(expected) == sorted(actual.get(name, []))
                if not same:
                    modifications += (
                        ["replace: " + name]
                        + [name + ": " + v for v in expected]
                        + ["-"]
                    )
            if modifications:
                changed = True
                if not m.check_mode:
                    body = (
                        "dn: "
                        + dn
                        + "\nchangetype: modify\n"
                        + "\n".join(modifications)
                        + "\n"
                    )
                    if cmd(["ldapmodify"] + args, body).returncode:
                        m.fail_json(msg="LDAP attribute reconciliation failed")
    m.exit_json(changed=changed)


if __name__ == "__main__":
    main()
