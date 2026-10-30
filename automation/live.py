#!/usr/bin/env python3
"""Run licensed live acceptance on an explicit disposable instance only."""

import argparse
from datetime import datetime, timezone
import json
import os
import re
from pathlib import Path
import subprocess
import sys
from common import ROOT, atomic_json


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--runtime", choices=["docker", "podman"], required=True)
    p.add_argument("--instance", required=True)
    p.add_argument("--port-base", type=int, required=True)
    p.add_argument("--start", type=int, default=1)
    p.add_argument("--end", type=int, default=10)
    args = p.parse_args()
    if not 1024 <= args.port_base <= 64000:
        p.error("port-base must be 1024–64000")
    if not re.fullmatch(r"validation-[a-z0-9-]{1,14}", args.instance):
        p.error("Live acceptance requires a dedicated validation-* instance")
    if not 1 <= args.start <= args.end <= 10:
        p.error("Invalid stage range")
    logs = ROOT / ".secrets" / args.instance / "acceptance"
    logs.mkdir(parents=True, exist_ok=True, mode=0o700)
    results = []
    for n in range(args.start, args.end + 1):
        for action in ["resolve", "resolve"]:
            lab = f"{n:02}"
            repeat = any(x["lab"] == lab for x in results)
            log = logs / f'{lab}-{"repeat" if repeat else "first"}.log'
            command = [
                "make",
                action,
                "LAB=" + lab,
                "RUNTIME=" + args.runtime,
                "INSTANCE=" + args.instance,
                "PORT_BASE=" + str(args.port_base),
            ]
            print(
                f'{args.runtime} lab {lab} {"repeat" if repeat else "first"}: running',
                flush=True,
            )
            with log.open("w") as f:
                os.chmod(log, 0o600)
                proc = subprocess.run(
                    command, cwd=ROOT, stdout=f, stderr=subprocess.STDOUT
                )
            text = log.read_text()
            recap = next(
                (
                    line
                    for line in text.splitlines()
                    if line.startswith("localhost ") and "changed=" in line
                ),
                "",
            )
            row = {
                "lab": lab,
                "repeat": repeat,
                "exit_code": proc.returncode,
                "recap": recap,
                "at": datetime.now(timezone.utc).isoformat(),
            }
            results.append(row)
            atomic_json(ROOT / ".build" / args.instance / "acceptance.json", results)
            print(
                f'{args.runtime} lab {lab}: {"passed" if proc.returncode==0 else "FAILED"}; {recap}',
                flush=True,
            )
            if proc.returncode:
                sys.exit(proc.returncode)
            # No changes means no schema reseed/identity issuance/connector restart.
            if repeat and "changed=0 " not in recap:
                print(
                    "Repeat run changed configuration; inspect its private task log.",
                    file=sys.stderr,
                )
                sys.exit(1)


if __name__ == "__main__":
    main()
