#!/usr/bin/python
"""Portable Compose lifecycle with actual before/after state comparison."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import os
from ansible.module_utils.basic import AnsibleModule

SECRET_NAME = re.compile(r"PASS|TOKEN|SECRET|LICENSE|KEY|CREDENTIAL|ROLE_ID", re.I)


def env_values(paths):
    """Values worth masking: secret-named ones, and long opaque ones of any name."""
    values = set()
    for path in paths:
        try:
            lines = Path(path).read_text().splitlines()
        except OSError:
            continue
        for line in lines:
            if "=" not in line or line.lstrip().startswith("#"):
                continue
            name, value = line.split("=", 1)
            value = value.strip().strip("\"'")
            secret = SECRET_NAME.search(name) and len(value) >= 4
            opaque = len(value) >= 16 and not re.search(r"[/:]", value)
            if secret or opaque:
                values.add(value)
    return values


def safe_output(text, env_files, lines=15, limit=1500):
    """Last lines of Compose output with environment values and tokens masked."""
    for value in sorted(env_values(env_files), key=len, reverse=True):
        text = text.replace(value, "<redacted>")
    text = re.sub(
        r"\b([A-Z0-9_]*(?:PASS|TOKEN|SECRET|LICENSE|KEY)[A-Z0-9_]*)=\S+",
        r"\1=<redacted>",
        text,
    )
    text = re.sub(r"\bhv[sbr]\.[A-Za-z0-9_-]+", "<redacted>", text)
    text = re.sub(r"[A-Za-z0-9+_=.-]{40,}", "<redacted>", text)
    return "\n".join(text.strip().splitlines()[-lines:])[-limit:]


def main():
    m = AnsibleModule(
        argument_spec=dict(
            argv=dict(type="list", elements="str", required=True),
            file=dict(required=True),
            project=dict(required=True),
            services=dict(type="list", elements="str", default=[]),
            operation=dict(choices=["up", "stop"], required=True),
            recreate=dict(type="bool", default=False),
        ),
        supports_check_mode=True,
    )
    for key in ["COMPOSE_FILE", "COMPOSE_PROFILES", "COMPOSE_PROJECT_NAME"]:
        os.environ.pop(key, None)
    p = m.params
    base = p["argv"] + ["-f", p["file"], "-p", p["project"]]
    env_files = [
        p["argv"][i + 1]
        for i, arg in enumerate(p["argv"][:-1])
        if arg == "--env-file"
    ] + [str(Path(p["file"]).parent / "backend.env")]

    def call(args, ok=True):
        result = subprocess.run(
            base + args, text=True, capture_output=True, timeout=600
        )
        if ok and result.returncode:
            m.fail_json(
                msg="Compose "
                + args[0]
                + " failed (environment values masked):\n"
                + safe_output(result.stderr or result.stdout, env_files),
                rc=result.returncode,
            )
        return result

    def snapshot():
        ids = call(["ps", "-a", "-q"]).stdout.split()
        if not ids:
            return {}
        engine = p["argv"][0] if p["argv"][0] in ["docker", "podman"] else "docker"
        out = subprocess.run(
            [engine, "inspect"] + ids, text=True, capture_output=True, timeout=30
        )
        if out.returncode:
            m.fail_json(msg="Cannot inspect current project containers")
        return {
            x["Config"]["Labels"].get("com.docker.compose.service", x.get("Name")): {
                "id": x["Id"],
                "status": x["State"]["Status"],
                "started": x["State"].get("StartedAt"),
            }
            for x in json.loads(out.stdout)
        }

    before = snapshot()
    if m.check_mode:
        m.exit_json(
            changed=False,
            skipped=True,
            msg="Compose check mode does not prove convergence; use live repeat validation",
        )
    if p["operation"] == "up" and any(
        name in ["backend", "frontend"] for name in p["services"]
    ):
        # Build missing local images before `up` resolves image IDs. This avoids
        # a spurious second-run recreation through the Podman Docker API.
        # Resolved config remains in memory; never return its secret env values.
        config = json.loads(call(["config", "--format", "json"]).stdout)
        engine = p["argv"][0] if p["argv"][0] in ["docker", "podman"] else "docker"
        for name in p["services"]:
            service = config.get("services", {}).get(name, {})
            if not service.get("build"):
                continue
            image = service.get("image") or p["project"] + "-" + name
            exists = subprocess.run(
                [engine, "image", "inspect", image],
                text=True,
                capture_output=True,
                timeout=30,
            )
            if exists.returncode:
                call(["build", name])
    args = ["up", "-d", "--no-deps"] if p["operation"] == "up" else ["stop"]
    if p["operation"] == "up" and p["recreate"]:
        args += ["--force-recreate"]
    call(args + p["services"])
    after = snapshot()
    m.exit_json(changed=before != after, services=list(after))


if __name__ == "__main__":
    main()
