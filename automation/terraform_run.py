"""Protected Terraform execution and explicit, structure-checked import."""

import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request
import urllib.error
from common import ROOT, WorkshopError, atomic_json, run


def get(address, path, token):
    try:
        with urllib.request.urlopen(
            urllib.request.Request(
                address + "/v1/" + path, headers={"X-Vault-Token": token}
            ),
            timeout=15,
        ) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise WorkshopError(f"Vault structure inspection failed ({e.code})") from None


def resources(features):
    features = set(features)
    result = {'vault_mount.lab["secret"]': ("sys/mounts", "secret", "kv")}
    if "database" in features:
        result['vault_mount.lab["database"]'] = ("sys/mounts", "database", "database")
    for name in ["approle", "jwt"]:
        if name in features:
            result[f'vault_auth_backend.lab["{name}"]'] = ("sys/auth", name, name)
    for name, feature in [
        ("zt-static", "kv"),
        ("app-policy", "approle"),
        ("zero-trust-jwt-lab", "jwt"),
    ]:
        if feature in features:
            result[f'vault_policy.lab["{name}"]'] = (
                "sys/policies/acl/" + name,
                name,
                "policy",
            )
    return result


def execute(config, action, level=None):
    private = Path(config["zt_private"])
    level = int(level or config["zt_lab"])
    if level < 3:
        raise WorkshopError(
            "Terraform begins at lab 03; baseline labs have no Vault structure"
        )
    token = json.loads((private / "tokens/terraform").read_text())["token"]
    addr = "http://127.0.0.1:" + str(config["zt_port_base"] + 20)
    env = os.environ.copy()
    env.update(VAULT_TOKEN=token, VAULT_ADDR=addr, TF_IN_AUTOMATION="1")
    # Ignore inherited namespaces and Terraform argument injection.
    for key in list(env):
        if key == "VAULT_NAMESPACE" or key.startswith(("TF_CLI_ARGS", "TF_VAR_")):
            env.pop(key)
    state = private / "terraform/terraform.tfstate"
    state.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    env["TF_DATA_DIR"] = str(private / "terraform/data")
    base = ["terraform", "-chdir=" + str(ROOT / "terraform/workshop")]
    run(
        base
        + [
            "init",
            "-input=false",
            "-lockfile=readonly",
            "-reconfigure",
            "-backend-config=path=" + str(state),
        ],
        env=env,
        capture=True,
        timeout=300,
    )
    if state.exists():
        high = (
            json.loads(state.read_text())
            .get("outputs", {})
            .get("contract", {})
            .get("value", {})
            .get("level", 0)
        )
        if high > level:
            raise WorkshopError(
                "Earlier Terraform level refused; select a fresh instance"
            )
    existing = (
        set(run(base + ["state", "list"], env=env, capture=True).splitlines())
        if state.exists()
        else set()
    )
    wanted = resources(config["zt_manifest"]["labs"][level - 1]["features"])
    unmanaged = []
    for resource, (api, name, kind) in wanted.items():
        if resource in existing:
            continue
        data = get(addr, api, token)
        item = (data or {}).get("data", data or {})
        if kind == "policy":
            found = data is not None
        else:
            found = name + "/" in item
            if found:
                remote = item[name + "/"]
                if remote.get("type") != kind or (
                    kind == "kv" and remote.get("options", {}).get("version") != "2"
                ):
                    raise WorkshopError(
                        f"Incompatible existing structure: {name}; automatic replacement refused"
                    )
        if found:
            unmanaged.append((resource, name))
    if unmanaged and action != "adopt":
        raise WorkshopError(
            "Unmanaged structure exists. Inspect it, then run make adopt LAB="
            + f"{level:02}"
            + ". No apply performed."
        )
    if action == "adopt":
        # A provider read failure after creation can mark a valid mount tainted.
        # Clear only exact, type-checked workshop mount identities; never replace.
        state_data = json.loads(state.read_text()) if state.exists() else {}
        for resource in state_data.get("resources", []):
            if resource.get("type") not in ["vault_mount", "vault_auth_backend"]:
                continue
            for instance in resource.get("instances", []):
                if instance.get("status") != "tainted":
                    continue
                name = instance.get("index_key")
                address = f"{resource['type']}.{resource['name']}[{json.dumps(name)}]"
                if address not in wanted:
                    raise WorkshopError(
                        "Unrecognized tainted resource; automatic recovery refused"
                    )
                api, expected, kind = wanted[address]
                remote = get(addr, api, token) or {}
                item = remote.get("data", remote).get(expected + "/", {})
                if item.get("type") != kind or (
                    kind == "kv" and item.get("options", {}).get("version") != "2"
                ):
                    raise WorkshopError(
                        "Tainted resource does not match the expected live mount; restore or inspect it manually"
                    )
                print(
                    "Clearing failed-create taint for verified live mount " + expected
                )
                run(base + ["untaint", address], env=env, capture=True)
        # Imports only; proposed policy changes are shown by the subsequent plan.
        for resource, name in unmanaged:
            print(f"Importing existing {name} as {resource}")
            run(
                base
                + ["import", "-input=false", f"-var=level={level}", resource, name],
                env=env,
                capture=True,
            )
        print("Ownership imports complete; inspect the following plan before resolve.")

    def plan():
        p = subprocess.run(
            base
            + ["plan", "-input=false", "-detailed-exitcode", f"-var=level={level}"],
            env=env,
            text=True,
            capture_output=True,
            timeout=300,
        )
        diagnostics = private / "terraform/last-plan.log"
        diagnostics.write_text(p.stdout + "\n" + p.stderr)
        os.chmod(diagnostics, 0o600)
        if p.returncode not in [0, 2]:
            raise WorkshopError(
                "Terraform plan failed; inspect private terraform/last-plan.log"
            )
        # Structural plans contain policies and paths only, no secret resources.
        print(p.stdout)
        return p.returncode

    try:
        rc = plan()
        if action == "apply" and rc == 2:
            applied = subprocess.run(
                base
                + ["apply", "-input=false", "-auto-approve", f"-var=level={level}"],
                env=env,
                text=True,
                capture_output=True,
                timeout=300,
            )
            diagnostics = private / "terraform/last-apply.log"
            diagnostics.write_text(applied.stdout + "\n" + applied.stderr)
            os.chmod(diagnostics, 0o600)
            if applied.returncode:
                raise WorkshopError(
                    "Terraform apply failed; inspect private terraform/last-apply.log"
                )
            if plan() != 0:
                raise WorkshopError("Post-apply Terraform plan is not empty")
        if action == "apply":
            out = json.loads(
                run(base + ["output", "-json", "contract"], env=env, capture=True)
            )
            if (
                set(out)
                != set(["schema_version", "level", "mounts", "auth", "policies"])
                or out["schema_version"] != 1
            ):
                raise WorkshopError("Unexpected Terraform output contract")
            atomic_json(Path(config["zt_build"]) / "terraform.json", out)
            print("structure_changed=" + str(rc == 2).lower())
        if action == "drift" and rc == 2:
            raise WorkshopError("Terraform structure differs from desired state")
    finally:
        for f in state.parent.glob("*.tfstate*"):
            os.chmod(f, 0o600)


if __name__ == "__main__":
    try:
        execute(
            json.loads(Path(sys.argv[1]).read_text()),
            sys.argv[2],
            sys.argv[3] if len(sys.argv) > 3 else None,
        )
    except (WorkshopError, OSError, ValueError) as e:
        print("ERROR: " + str(e), file=sys.stderr)
        sys.exit(1)
