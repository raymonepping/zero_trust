#!/usr/bin/env python3
"""Validated Make dispatch. Configuration lives in Ansible and Terraform."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys
from common import (
    ROOT,
    WorkshopError,
    atomic_json,
    digest,
    discover,
    lock,
    manifest,
    run,
)

ACTIONS = {
    "help",
    "deps",
    "doctor",
    "labs",
    "up",
    "down",
    "status",
    "prepare",
    "resolve",
    "verify",
    "plan",
    "drift",
    "adopt",
    "unseal",
    "check",
    "reset",
    "bootstrap",
}
LAB_ACTIONS = {"prepare", "resolve", "verify", "plan", "drift", "adopt"}


def parse_goals(goals, lab):
    if not goals:
        goals = ["help"]
    if len(goals) == 3 and goals[0] in LAB_ACTIONS and goals[1] == "lab" and not lab:
        action, _, lab = goals
    elif len(goals) == 1:
        action = goals[0]
    else:
        raise WorkshopError(
            "Use one action: make resolve LAB=03 or make resolve lab 03; do not mix spellings/goals"
        )
    if action not in ACTIONS:
        raise WorkshopError(f"Unknown action: {action}")
    if action in LAB_ACTIONS and lab not in [f"{n:02}" for n in range(1, 11)]:
        raise WorkshopError("LAB must be a two-digit ID 01–10")
    if action not in LAB_ACTIONS and lab:
        raise WorkshopError(f"{action} does not accept LAB")
    return action, lab


def missing_inputs(root=ROOT):
    """Compose fails obscurely without its env files, so name them up front."""
    hints = {
        "config/defaults.env": "restore it from version control; it sets VAULT_IMAGE",
        ".env": "copy .env.example to .env and set VAULT_LICENSE",
    }
    return [f"{k} ({v})" for k, v in hints.items() if not (root / k).is_file()]


def prepare_existing(config, private):
    atomic_json(private / "run.json", config)
    env = os.environ.copy()
    env.update(
        ANSIBLE_CONFIG=str(ROOT / "ansible.cfg"),
        ANSIBLE_LOCAL_TEMP=str(ROOT / ".cache/ansible/tmp"),
    )
    run(
        [
            ROOT / ".venv/bin/ansible-playbook",
            "ansible/workshop.yml",
            "-e",
            "@" + str(private / "run.json"),
        ],
        env=env,
        timeout=1800,
    )


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--goals", nargs="*", default=[])
    p.add_argument("--lab", default="")
    args = p.parse_args(argv)
    action, lab = parse_goals(args.goals, args.lab)
    os.umask(0o077)
    data = manifest()
    if action == "help":
        print(
            "Zero Trust automation: deps doctor labs up down status prepare resolve verify plan drift adopt unseal check bootstrap\n"
            "Usage: make prepare LAB=03 RUNTIME=docker\n"
            "       make resolve lab 03 RUNTIME=podman\n"
            "Options: INSTANCE=workshop PORT_BASE=18000 OVERWRITE=1\n"
            "Start with make deps. Learner files: .build/<INSTANCE>/backend/. No destructive reset is automatic."
        )
        return
    if action == "labs":
        for row in data["labs"]:
            print(f"{row['id']}  {row['connector']:<20} {row['title']}")
        print("Optional legacy connector: dynamic")
        return
    if action == "check":
        run([sys.executable, "automation/check.py"], timeout=600)
        return
    if action == "deps":
        run([sys.executable, "-m", "venv", ".venv"], timeout=120)
        run(
            [
                ROOT / ".venv/bin/python",
                "-m",
                "pip",
                "install",
                "--disable-pip-version-check",
                "-r",
                "automation/requirements.txt",
            ],
            timeout=600,
        )
        env = os.environ.copy()
        env.update(
            ANSIBLE_CONFIG=str(ROOT / "ansible.cfg"),
            ANSIBLE_LOCAL_TEMP=str(ROOT / ".cache/ansible/tmp"),
        )
        run(
            [
                "terraform",
                "-chdir=terraform/workshop",
                "init",
                "-backend=false",
                "-input=false",
            ],
            timeout=300,
        )
        return
    instance = os.environ.get("INSTANCE") or "workshop"
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,24}", instance):
        raise WorkshopError("INSTANCE must match [a-z][a-z0-9-]{0,24}")
    port_base = os.environ.get("PORT_BASE") or "18000"
    if not port_base.isdigit() or not 1024 <= int(port_base) <= 64000:
        raise WorkshopError("PORT_BASE must be 1024–64000")
    runtime = os.environ.get("RUNTIME") or "auto"
    if runtime not in ["auto", "docker", "podman"]:
        raise WorkshopError("RUNTIME must be auto, docker or podman")
    if (os.environ.get("OVERWRITE") or "0") not in ["0", "1"]:
        raise WorkshopError("OVERWRITE must be 0 or 1")
    edition = os.environ.get("VAULT_EDITION") or "enterprise"
    if edition not in ["enterprise", "community"]:
        raise WorkshopError("VAULT_EDITION must be enterprise or community")
    target = discover(runtime)
    project = "zt-" + instance
    build = ROOT / ".build" / instance
    private = ROOT / ".secrets" / instance
    if action == "reset":
        raise WorkshopError(
            "Destructive reset is unsupported. Choose a new INSTANCE and PORT_BASE; down preserves volumes."
        )
    if action == "doctor":
        print(
            json.dumps(
                {
                    **target,
                    "project": project,
                    "port_base": int(port_base),
                    "architecture": os.uname().machine,
                    "environment_file_present": (ROOT / ".env").is_file(),
                },
                indent=2,
            )
        )
        for tool in ["terraform", str(ROOT / ".venv/bin/ansible-playbook")]:
            run([tool, "--version"], capture=True)
        return
    missing = missing_inputs()
    if missing:
        raise WorkshopError("Missing required file: " + "; ".join(missing))
    with lock(target["identity"], project):
        record = build / "last-attempt.json"
        previous = json.loads(record.read_text()) if record.exists() else {}
        if previous.get("runtime") and previous["runtime"] != target["identity"]:
            raise WorkshopError(
                "Instance runtime changed. Use a different INSTANCE or restore its original target."
            )
        config = dict(
            zt_root=str(ROOT),
            zt_build=str(build),
            zt_private=str(private),
            zt_project=project,
            zt_runtime=target["engine"],
            zt_compose=target["compose"]
            + [
                "--env-file",
                str(ROOT / "config/defaults.env"),
                "--env-file",
                str(ROOT / ".env"),
            ],
            zt_port_base=int(port_base),
            zt_vault_edition=edition,
            zt_action=action,
            zt_lab=lab,
            zt_overwrite=(os.environ.get("OVERWRITE") or "0") == "1",
            zt_target=target["identity"],
            zt_manifest=data,
            zt_digest=digest(),
            zt_revision=run(["git", "rev-parse", "HEAD"], capture=True),
        )
        if action == "status":
            from verify import status

            print(json.dumps(status(config), indent=2))
            return
        attempt = dict(
            action=action,
            lab=lab,
            runtime=target["identity"],
            digest=config["zt_digest"],
            at=datetime.now(timezone.utc).isoformat(),
            result="running",
        )
        atomic_json(record, attempt)
        if (
            action not in ["plan", "drift", "adopt", "verify"]
            and (build / "verification.json").exists()
        ):
            stale = json.loads((build / "verification.json").read_text())
            stale["result"] = "stale"
            atomic_json(build / "verification.json", stale)
        try:
            if action == "verify":
                from verify import verify

                verify(config)
            elif action in ["plan", "drift", "adopt"]:
                from terraform_run import execute

                execute(config, action)
            elif (
                action == "prepare"
                and int(lab) > 1
                and (private / "compose.yml").exists()
            ):
                # A correct manual previous solution must not be replaced merely
                # to establish the next exercise boundary.
                from verify import verify

                prior = {**config, "zt_lab": f"{int(lab)-1:02}"}
                try:
                    verify(prior)
                except WorkshopError:
                    prepare_existing(config, private)
                else:
                    atomic_json(
                        build / "prepared.json",
                        {
                            "lab": lab,
                            "level": int(lab) - 1,
                            "digest": config["zt_digest"],
                        },
                    )
                    print(
                        "Previous lab verified live; its manual solution was preserved."
                    )
            else:
                atomic_json(private / "run.json", config)
                env = os.environ.copy()
                env.update(
                    ANSIBLE_CONFIG=str(ROOT / "ansible.cfg"),
                    ANSIBLE_LOCAL_TEMP=str(ROOT / ".cache/ansible/tmp"),
                )
                env["ANSIBLE_COLLECTIONS_PATH"] = str(
                    ROOT / ".cache/ansible/collections"
                )
                run(
                    [
                        ROOT / ".venv/bin/ansible-playbook",
                        "ansible/workshop.yml",
                        "-e",
                        "@" + str(private / "run.json"),
                    ],
                    env=env,
                    timeout=1800,
                )
                if action == "resolve":
                    from verify import verify

                    verify(config)
            attempt["result"] = "passed"
            atomic_json(record, attempt)
        except BaseException:
            attempt["result"] = "failed"
            atomic_json(record, attempt)
            raise
        print(f"{action} {lab or instance}: passed")


if __name__ == "__main__":
    try:
        main()
    except (WorkshopError, ValueError, KeyError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
