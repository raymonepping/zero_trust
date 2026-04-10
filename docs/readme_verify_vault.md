# verify_vault.sh

**Location:** `scripts/verify_vault.sh`  
**Audience:** students and engineers

This script performs a focused Vault sanity check for the local workshop stack.

It answers four practical questions:

- is the Vault container up?
- is Vault reachable from the host?
- is Vault initialized and unsealed?
- if a valid `VAULT_TOKEN` is available, which secrets engines and auth methods are enabled?

It is a read-only diagnostic helper. It does not unseal Vault, write configuration, or enable any mounts.

---

## When to use it

Use this script when:

- you want to confirm Vault is ready before running [scripts/setup_vault.sh](../scripts/setup_vault.sh)
- the backend cannot connect to Vault
- you are unsure whether Vault is still sealed
- you want a quick summary of mounted secrets engines and auth methods
- a colleague says "Vault is up" but the workshop still fails at the Vault layer

---

## Usage

From the repository root:

```bash
./scripts/verify_vault.sh
```

The script uses the local workshop defaults unless you override them with environment variables.

---

## Defaults and inputs

The script uses:

```bash
VAULT_ADDR=http://127.0.0.1:8200
VAULT_CONTAINER=zero_trust_vault
```

Optional environment variables that affect behavior:

```bash
VAULT_ADDR
VAULT_CONTAINER
VAULT_TOKEN
```

Examples:

```bash
VAULT_ADDR=http://localhost:8200 ./scripts/verify_vault.sh
```

and, when you want mount listings:

```bash
export VAULT_TOKEN=...
./scripts/verify_vault.sh
```

---

## What the script checks

### 1. Vault container state

The script inspects:

```text
zero_trust_vault
```

and prints:

- container name
- runtime state
- health state when the container defines a healthcheck

This confirms the container itself is alive before making any host-side API calls.

### 2. Vault host reachability

The script checks the unauthenticated health endpoint:

```text
${VAULT_ADDR}/v1/sys/health
```

This confirms:

- the host can reach Vault
- Docker or Podman is publishing port `8200`
- the HTTP API is responding

### 3. Vault health summary

The script fetches the health endpoint and prints a compact summary:

- `initialized`
- `sealed`
- `standby`
- `version`
- `enterprise`
- `cluster_name`

This is the fastest way to confirm whether the local workshop Vault is actually usable.

### 4. Seal state

The script extracts the `sealed` boolean from the health response.

If Vault is still sealed, it prints a warning and does not pretend the stack is ready.

This is important because a reachable Vault is not the same thing as a usable Vault. A sealed Vault rejects normal operational requests.

### 5. Token-gated mount listing

If both of these are true:

- the `vault` CLI is installed
- `VAULT_TOKEN` is set

then the script also:

1. validates the token with `vault token lookup`
2. lists enabled secrets engines with `vault secrets list`
3. lists enabled auth methods with `vault auth list`

This gives you a very useful operational snapshot of the workshop's Vault state.

---

## Two operating modes

### Mode 1: no `VAULT_TOKEN`

Without `VAULT_TOKEN`, the script still provides:

- container status
- host reachability
- initialization state
- seal state

and then stops before token-gated CLI operations.

That makes it safe for quick host-side checks even before you authenticate.

### Mode 2: valid `VAULT_TOKEN`

With `VAULT_TOKEN` set, the script also reports:

- whether the token is valid
- enabled secrets engines
- enabled auth methods

This is the mode you want when validating whether the workshop Vault configuration has actually been applied.

---

## Example output shape

Typical output looks like:

```text
==> Vault container status
==> Vault host reachability
==> Vault health summary
==> Vault token lookup sanity
==> Enabled secrets engines
==> Enabled auth methods
==> Summary
```

If `VAULT_TOKEN` is missing, the script stops after the health and seal checks and prints a clear warning that mount listings were skipped.

---

## How to interpret results

### Case: Vault is reachable and unsealed

This is the expected healthy state for workshop use. At that point:

- `setup_vault.sh` can run
- backend Vault-dependent modes have a chance to work
- further checks should move to auth methods, policies, or secrets configuration

### Case: Vault is reachable but sealed

This means the container is up, but Vault is not usable yet.

Run the unseal workflow:

- [scripts/unseal_vault.sh](../scripts/unseal_vault.sh)
- [docs/readme_vault_unseal.md](./readme_vault_unseal.md)

### Case: Vault is reachable, unsealed, but mount listings are skipped

This usually means one of:

- `VAULT_TOKEN` is not set
- the `vault` CLI is not installed on the host

That is not a failure for the health check itself. It just means the script cannot perform authenticated inspection.

### Case: token lookup fails

This means:

- `VAULT_TOKEN` is set
- but the token is invalid, expired, or scoped incorrectly

At that point, refresh the token or log in again. For username/password-based access, use:

- [scripts/vault_login.sh](../scripts/vault_login.sh)
- [docs/readme_vault_login.md](./readme_vault_login.md)

### Case: `database/`, `secret/`, `approle/`, `jwt/`, or `ldap/` are missing

That usually means the relevant Vault setup phases were not run yet.

Use:

```bash
./scripts/setup_vault.sh --phase 01
./scripts/setup_vault.sh --phase 02
./scripts/setup_vault.sh --phase 03
./scripts/setup_vault.sh --phase 04
./scripts/setup_vault.sh --phase 05
```

depending on which capabilities you expect to exist.

---

## What the script does not check

This script does not:

- unseal Vault
- verify individual policies
- verify individual roles
- verify dynamic credentials are being issued
- verify CIBA Vault-side setup
- verify audit logging configuration in depth

Those are all deeper configuration checks. This script is intentionally a first-pass readiness probe.

---

## Relationship to other Vault scripts

- [scripts/unseal_vault.sh](../scripts/unseal_vault.sh)  
  Makes Vault usable by unsealing it.

- [scripts/vault_login.sh](../scripts/vault_login.sh)  
  Obtains a user-scoped Vault token through LDAP or userpass.

- [scripts/setup_vault.sh](../scripts/setup_vault.sh)  
  Applies the workshop Vault configuration.

`verify_vault.sh` sits before those scripts in the troubleshooting chain. It tells you whether Vault is fundamentally alive and ready for the next step.

---

## Related documents

- [scripts/verify_vault.sh](../scripts/verify_vault.sh)
- [scripts/unseal_vault.sh](../scripts/unseal_vault.sh)
- [scripts/vault_login.sh](../scripts/vault_login.sh)
- [scripts/setup_vault.sh](../scripts/setup_vault.sh)
- [docs/readme_setup_vault.md](./readme_setup_vault.md)
- [docs/readme_vault_unseal.md](./readme_vault_unseal.md)
- [docs/readme_vault_login.md](./readme_vault_login.md)
- [docker-compose.yml](../docker-compose.yml)
