"""Check private Terraform state for known local credential values, without outputting them."""

import json
from pathlib import Path
from common import ROOT, WorkshopError


def audit(private):
    private = Path(private)
    values = []
    for file in [
        private / "init.json",
        private / "runtime.json",
        private / "keycloak.json",
        *list((private / "tokens").glob("*")),
    ]:
        if not file.is_file():
            continue

        def collect(item):
            if isinstance(item, dict):
                for child in item.values():
                    collect(child)
            elif isinstance(item, list):
                for child in item:
                    collect(child)
            elif isinstance(item, str) and len(item) > 16:
                values.append(item)

        collect(json.loads(file.read_text()))
    states = list((private / "terraform").glob("*.tfstate*"))
    for file in states:
        contents = file.read_text()
        if any(secret in contents for secret in values):
            raise WorkshopError(
                "Known private credential found in Terraform state; content withheld"
            )
    return len(states)


if __name__ == "__main__":
    count = 0
    for private in (ROOT / ".secrets").glob("validation-*"):
        count += audit(private)
    print(
        f"Private state audit passed for {count} state/backup files; no credential values emitted."
    )
