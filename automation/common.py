"""Runtime discovery and process helpers. No lab configuration belongs here."""

import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


class WorkshopError(RuntimeError):
    pass


def run(argv, *, capture=False, env=None, timeout=120, input=None):
    try:
        clean_env = dict(env or os.environ)
        for key in ["COMPOSE_FILE", "COMPOSE_PROFILES", "COMPOSE_PROJECT_NAME"]:
            clean_env.pop(key, None)
        p = subprocess.run(
            [str(x) for x in argv],
            cwd=ROOT,
            env=clean_env,
            input=input,
            text=True,
            capture_output=capture,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise WorkshopError(
            f"Could not execute {argv[0]} ({type(exc).__name__})"
        ) from None
    if p.returncode:
        # Captured output can contain credentials. It must never enter diagnostics.
        raise WorkshopError(
            f"{Path(str(argv[0])).name} failed (exit {p.returncode}); check service readiness and private configuration"
        )
    return p.stdout.strip() if capture else ""


def manifest():
    data = json.loads((ROOT / "labs/manifest.yml").read_text())
    ids = [x["id"] for x in data["labs"]]
    if ids != [f"{i:02}" for i in range(1, 11)]:
        raise WorkshopError("Invalid lab manifest IDs")
    for lab in data["labs"]:
        if not (ROOT / f"data/connector.{lab['connector']}.js").is_file():
            raise WorkshopError("Missing local connector reference")
    return data


def discover(runtime="auto"):
    engines = []
    for candidate in (["docker", "podman"] if runtime == "auto" else [runtime]):
        if not shutil.which(candidate):
            continue
        try:
            info = json.loads(
                run(
                    [
                        candidate,
                        "info",
                        "--format",
                        "json" if candidate == "podman" else "{{json .}}",
                    ],
                    capture=True,
                    timeout=20,
                )
            )
        except (WorkshopError, ValueError):
            continue
        if candidate == "docker":
            endpoint = run(
                [
                    "docker",
                    "context",
                    "inspect",
                    "--format",
                    "{{json .Endpoints.docker.Host}}",
                ],
                capture=True,
            )
            identity = json.dumps(
                [
                    info.get("Name"),
                    info.get("KernelVersion"),
                    info.get("NCPU"),
                    info.get("MemTotal"),
                ]
            )
            try:
                version = run(
                    ["docker", "compose", "version", "--short"],
                    capture=True,
                    timeout=15,
                )
                compose = ["docker", "compose"]
            except WorkshopError:
                compose = ["docker-compose"]
                version = run(
                    compose + ["version", "--short"], capture=True, timeout=15
                )
        else:
            connection = run(
                ["podman", "system", "connection", "list", "--format", "json"],
                capture=True,
            )
            defaults = [x for x in json.loads(connection) if x.get("Default")]
            host = info.get("host", {})
            identity = json.dumps(
                [
                    host.get("hostname"),
                    host.get("kernel"),
                    host.get("cpus"),
                    host.get("memTotal"),
                ]
            )
            compose = ["podman", "compose"]
            version = run(compose + ["version"], capture=True, timeout=20)
        match = re.search(r"(?<!\d)(\d+)\.(\d+)\.(\d+)", version)
        if (
            not match
            or tuple(map(int, match.groups())) < (2, 24, 0)
            or int(match.group(1)) != 2
        ):
            raise WorkshopError(
                "Use Compose v2 >=2.24,<3; for Podman select that external Compose provider (PODMAN_COMPOSE_PROVIDER)."
            )
        engines.append(
            dict(
                engine=candidate,
                compose=compose,
                provider_version=version,
                identity=hashlib.sha256(identity.encode()).hexdigest(),
            )
        )
    if len(engines) != 1:
        raise WorkshopError(
            "Select one reachable runtime explicitly: RUNTIME=docker or RUNTIME=podman (auto requires exactly one healthy engine)"
        )
    return engines[0]


@contextlib.contextmanager
def lock(identity, project):
    path = (
        ROOT
        / ".cache/automation/locks"
        / hashlib.sha256(f"{identity}:{project}".encode()).hexdigest()
    )
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open("a") as handle:
        os.chmod(path, 0o600)
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise WorkshopError(
                "Another workshop operation is active for this runtime/project"
            ) from None
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def digest():
    h = hashlib.sha256()
    for directory in [
        "automation",
        "ansible",
        "terraform",
        "labs",
        "data",
        "config",
        "backend",
        "frontend",
        "ldap",
    ]:
        for p in sorted((ROOT / directory).rglob("*")):
            if (
                p.is_file()
                and not any(
                    x in p.parts for x in ["__pycache__", ".terraform", "node_modules"]
                )
                and p.suffix
                in [
                    ".py",
                    ".yml",
                    ".j2",
                    ".tf",
                    ".hcl",
                    ".js",
                    ".sql",
                    ".env",
                    ".json",
                    ".jsx",
                    ".css",
                    ".ldif",
                ]
            ):
                h.update(str(p.relative_to(ROOT)).encode())
                h.update(p.read_bytes())
    for name in [
        "Makefile",
        "ansible.cfg",
        "backend/Dockerfile",
        "frontend/Dockerfile",
    ]:
        h.update(name.encode())
        h.update((ROOT / name).read_bytes())
    return h.hexdigest()


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_suffix(".tmp")
    with tmp.open("w") as f:
        os.chmod(tmp, 0o600)
        json.dump(data, f, indent=2)
        f.write("\n")
    tmp.replace(path)
