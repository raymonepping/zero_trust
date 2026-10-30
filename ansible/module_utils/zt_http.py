"""Credential-safe JSON HTTP client for local workshop modules."""

import json
import os
from pathlib import Path
import urllib.request
import urllib.error


def request(base, path, method="GET", body=None, token=None, headers=None):
    hdr = {"Content-Type": "application/json", **(headers or {})}
    if token:
        hdr["X-Vault-Token"] = token
    payload = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        base.rstrip("/") + "/" + path.lstrip("/"),
        data=payload,
        method=method,
        headers=hdr,
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        return e.code, {}  # Server errors can contain SQL, credentials or JWTs.


def save(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        os.chmod(tmp, 0o600)
        json.dump(data, f)
        f.flush()
        os.fsync(f.fileno())
    tmp.replace(path)


def subset(actual, desired):
    if isinstance(desired, dict):
        return isinstance(actual, dict) and all(
            k in actual and subset(actual[k], v) for k, v in desired.items()
        )
    if isinstance(desired, list):
        return isinstance(actual, list) and sorted(actual, key=str) == sorted(
            desired, key=str
        )
    return actual == desired
