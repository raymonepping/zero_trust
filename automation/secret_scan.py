"""Scan new automation source for high-confidence credential material only."""

from pathlib import Path
import re
from common import ROOT, WorkshopError

PATTERNS = [
    re.compile(r"\bhv[sb]\.[A-Za-z0-9_-]{20,}"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}"),
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
]


def scan():
    paths = []
    for directory in [
        "automation",
        "ansible",
        "terraform/workshop",
        "labs",
        "docs/automation",
        "tests/automation",
        "config",
    ]:
        for p in (ROOT / directory).rglob("*"):
            if (
                p.is_file()
                and not any(x in p.parts for x in [".terraform", "__pycache__"])
                and p.suffix
                in [
                    ".py",
                    ".md",
                    ".yml",
                    ".tf",
                    ".hcl",
                    ".j2",
                    ".env",
                    ".sql",
                    ".txt",
                    ".cjs",
                ]
            ):
                paths.append(p)
    for p in paths:
        text = p.read_text()
        if any(pattern.search(text) for pattern in PATTERNS):
            raise WorkshopError(
                "Potential credential material in "
                + str(p.relative_to(ROOT))
                + "; content withheld"
            )
    print("Automation source credential scan passed; private runtime files excluded.")


if __name__ == "__main__":
    scan()
