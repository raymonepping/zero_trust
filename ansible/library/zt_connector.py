#!/usr/bin/python
"""Protect edited connectors, then atomically deploy a local reference."""

import hashlib
import json
from pathlib import Path
from datetime import datetime, timezone
import os
from ansible.module_utils.basic import AnsibleModule


def main():
    m = AnsibleModule(
        argument_spec=dict(
            root=dict(required=True),
            build=dict(required=True),
            private=dict(required=True),
            connector=dict(required=True),
            overwrite=dict(type="bool", default=False),
        ),
        supports_check_mode=True,
    )
    p = m.params
    root = Path(p["root"])
    dest = Path(p["build"]) / "backend/connector.js"
    choices = list((root / "data").glob("connector.*.js"))
    source = root / "data" / ("connector." + p["connector"] + ".js")
    if source not in choices:
        m.fail_json(msg="Connector must be a local reference example")
    desired = source.read_bytes()
    actual = dest.read_bytes() if dest.exists() else None
    receipt = Path(p["private"]) / "connector.json"
    previous = json.loads(receipt.read_text()) if receipt.exists() else {}
    managed = (
        actual is not None
        and previous.get("sha256") == hashlib.sha256(actual).hexdigest()
    )
    changed = actual != desired
    if (
        changed
        and actual is not None
        and not managed
        and all(actual != f.read_bytes() for f in choices)
    ):
        if not p["overwrite"]:
            m.fail_json(
                msg="Learner changes protected. Verify the manual solution or use OVERWRITE=1 for private backup and replacement."
            )
        if not m.check_mode:
            backup = (
                Path(p["private"])
                / "learner-backups"
                / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%f.js")
            )
            backup.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            backup.write_bytes(actual)
            os.chmod(backup, 0o600)
    if changed and not m.check_mode:
        tmp = dest.with_suffix(".tmp")
        tmp.write_bytes(desired)
        os.chmod(tmp, 0o600)
        tmp.replace(dest)
    record = {
        "connector": p["connector"],
        "sha256": hashlib.sha256(desired).hexdigest(),
    }
    if not m.check_mode and previous != record:
        receipt.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        receipt.write_text(json.dumps(record))
        os.chmod(receipt, 0o600)
        changed = True
    m.exit_json(changed=changed)


if __name__ == "__main__":
    main()
