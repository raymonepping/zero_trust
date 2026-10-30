import ast
from pathlib import Path
import subprocess
import sys
import yaml
from common import ROOT, manifest, run


def main():
    from secret_scan import scan

    scan()
    data = manifest()
    for row in data["labs"]:
        for dependency in row["requires"]:
            assert dependency < row["id"]
    for directory in [
        "automation",
        "ansible/library",
        "ansible/module_utils",
        "tests/automation",
    ]:
        for p in (ROOT / directory).glob("*.py"):
            ast.parse(p.read_text(), filename=str(p))
    for p in (ROOT / "ansible").rglob("*.yml"):
        yaml.safe_load(p.read_text())
    for p in (ROOT / "data").glob("connector.*.js"):
        run(["node", "--check", str(p)], capture=True)
    run(["node", "--test", "tests/automation/test_agent.cjs"], timeout=30)
    run(
        [sys.executable, "-m", "unittest", "discover", "-s", "tests/automation", "-v"],
        timeout=120,
    )
    run([sys.executable, "automation/lint.py"], timeout=120)
    run(
        [ROOT / ".venv/bin/ansible-playbook", "ansible/workshop.yml", "--syntax-check"],
        timeout=120,
    )
    run(
        ["terraform", "-chdir=terraform/workshop", "fmt", "-check", "-recursive"],
        timeout=120,
    )
    run(["terraform", "-chdir=terraform/workshop", "validate"], timeout=120)
    print(
        "Static, dispatch and contract checks passed. Live runtime checks are separate."
    )


if __name__ == "__main__":
    main()
