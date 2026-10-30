#!/usr/bin/python
"""Validate license presence without returning, copying or printing its value."""

import os
from pathlib import Path
import re
from ansible.module_utils.basic import AnsibleModule


def dotenv_license(text):
    match = re.search(r"^\s*(?:export\s+)?VAULT_LICENSE\s*=\s*(.*)$", text, re.M)
    if not match:
        return ""
    value = match.group(1).strip()
    if value.startswith(('"', "'")):
        quote = value[0]
        start = match.start(1) + match.group(1).index(quote) + 1
        end = text.find(quote, start)
        if end < 0:
            raise ValueError("Unclosed license quote")
        return text[start:end].strip()
    return value.split(" #", 1)[0].strip()


def main():
    m = AnsibleModule(
        argument_spec=dict(root=dict(required=True)), supports_check_mode=True
    )
    try:
        value = os.environ.get("VAULT_LICENSE", "").strip()
        env = Path(m.params["root"]) / ".env"
        if "VAULT_LICENSE" not in os.environ and env.is_file():
            value = dotenv_license(env.read_text())
        if not value:
            m.fail_json(
                msg="Set non-empty VAULT_LICENSE in .env; Compose passes it directly to Vault, matching vault_reference"
            )
        m.exit_json(changed=False)
    except (OSError, ValueError):
        m.fail_json(msg="Cannot read Vault license setting; check .env quoting")


if __name__ == "__main__":
    main()
