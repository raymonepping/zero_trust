#!/usr/bin/python
"""Validate a requested transition before any environment mutation."""

from pathlib import Path
import hashlib
import json
from ansible.module_utils.basic import AnsibleModule


def main():
    m = AnsibleModule(
        argument_spec=dict(
            root=dict(required=True),
            build=dict(required=True),
            private=dict(required=True),
            action=dict(required=True),
            lab=dict(default=""),
            overwrite=dict(type="bool", default=False),
        ),
        supports_check_mode=True,
    )
    p = m.params
    action = p["action"]
    level = int(p["lab"] or 1)
    build = Path(p["build"])
    private = Path(p["private"])
    state = private / "terraform/terraform.tfstate"
    high = 0
    if state.exists():
        data = json.loads(state.read_text())
        high = (
            data.get("outputs", {}).get("contract", {}).get("value", {}).get("level", 0)
        )
    desired = max(1, level - 1) if action == "prepare" else level
    if action in ["prepare", "resolve"] and high > desired:
        m.fail_json(
            msg="Earlier state would remove existing security structure. Choose a fresh INSTANCE and PORT_BASE."
        )
    path = build / "backend/connector.js"
    references = {
        hashlib.sha256(f.read_bytes()).hexdigest(): f.stem.split("connector.")[1]
        for f in (Path(p["root"]) / "data").glob("connector.*.js")
    }
    known = None
    if path.exists():
        known = references.get(hashlib.sha256(path.read_bytes()).hexdigest())
    receipt = private / "connector.json"
    if path.exists() and not known and receipt.exists():
        record = json.loads(receipt.read_text())
        if record.get("sha256") == hashlib.sha256(path.read_bytes()).hexdigest():
            known = record.get("connector")
    manifest = json.loads((Path(p["root"]) / "labs/manifest.yml").read_text())["labs"]
    current = next((int(x["id"]) for x in manifest if x["connector"] == known), 0)
    if action == "up":
        if path.exists() and not known:
            m.fail_json(
                msg="Learner code is protected. Resume its selected Compose services directly, or verify it before explicit resolution."
            )
        if high > current and current:
            m.fail_json(
                msg="Partial/later structure exists. Resume the intended lab with resolve LAB=NN; up will not choose a different connector."
            )
        desired = max(current, 1)
    if action == "prepare" and current >= level and level > 1:
        m.fail_json(
            msg="This exercise is already solved or a later connector is active; verify it or use a fresh instance."
        )
    if action == "resolve" and current > level:
        m.fail_json(
            msg="Backward connector transitions are unsupported; choose a fresh instance."
        )
    if action == "resolve" and path.exists() and not known and not p["overwrite"]:
        m.fail_json(
            msg="Learner connector differs from reference examples. Verify it, or resolve with OVERWRITE=1 to back it up privately."
        )
    prepared = build / "prepared.json"
    skip = (
        action == "prepare"
        and prepared.exists()
        and json.loads(prepared.read_text()).get("lab") == p["lab"]
    )
    m.exit_json(changed=False, level=desired, skip_prepare=skip)


if __name__ == "__main__":
    main()
