# vault_login.sh — Vault Authentication Script

**Location:** `scripts/vault_login.sh`
**Reads from:** `data/.vault.env`

This script authenticates to a Vault instance using a **username + password** auth method and sets the resulting token in your shell environment. It now supports both **LDAP** and **userpass**, with LDAP as the default for the local Vault Enterprise setup used in this workshop.

---

## When to use this script vs. `unseal_vault.sh`

| Script | Use when |
|--------|----------|
| `unseal_vault.sh` | Starting the local Docker Vault — applies unseal keys and prints the root token |
| `vault_login.sh` | Authenticating as a named user (local or HCP Vault) — reads `data/.vault.env` and exchanges credentials for a scoped token |

`unseal_vault.sh` gives you the **root token** — a superuser credential. `vault_login.sh` gives you a **scoped user token** through either LDAP or userpass. For day-to-day workshop use against the local Vault Enterprise instance with LDAP enabled, this is the right script to use.

---

## How to invoke it — two modes

This is the most unusual thing about this script. It behaves differently depending on whether you **source** it or **execute** it.

### Mode 1: `source` — exports directly into your shell

```bash
source ./scripts/vault_login.sh
```

Variables are exported directly into your current shell session:

```bash
VAULT_ADDR=https://...vault.cloud:8200
VAULT_TOKEN=hvs.CAESI...
VAULT_NAMESPACE=admin/repping-ns
```

After sourcing, any command you run in the same terminal — including `vault`, `setup_vault.sh`, or direct API calls — automatically uses these values. No copy-paste needed.

### Mode 2: `eval` — print then capture

```bash
eval "$(./scripts/vault_login.sh)"
```

The script prints `export` statements to stdout. `eval` captures them and runs them in the current shell. The end result is identical to sourcing, but this form is more portable across different shell setups and works well in CI/CD pipelines.

```bash
# What the script prints (before eval captures it):
export VAULT_ADDR='https://...vault.cloud:8200'
export VAULT_TOKEN='hvs.CAESI...'
export VAULT_NAMESPACE='admin/repping-ns'
```

### Why does it need to work both ways?

Shell subprocesses (scripts you execute with `./`) run in a **child process**. Environment variables set in a child process do not propagate back to the parent shell. `source` makes the script run in the *current* shell process, so its `export` calls take effect immediately. `eval` achieves the same by printing the export commands for the parent shell to run itself.

---

## The `data/.vault.env` file

This file holds the credentials and connection details the script reads. It lives in `data/` and is **not gitignored by default** — add it to `.gitignore` if it contains real credentials.

```bash
VAULT_AUTH_METHOD=ldap
VAULT_LOGIN_USERNAME=repping
VAULT_LOGIN_PASSWORD=changeme

VAULT_NAMESPACE="admin/repping-ns"
VAULT_ADDR="https://vault.example:8200"
```

| Variable | Purpose |
|----------|---------|
| `VAULT_AUTH_METHOD` | Auth method used by `vault login`; supported values are `ldap` and `userpass` |
| `VAULT_LOGIN_USERNAME` | Preferred username variable |
| `VAULT_LOGIN_PASSWORD` | Preferred password variable |
| `VAULT_ADDR` | Full URL of the Vault instance (local or HCP) |
| `VAULT_NAMESPACE` | Optional — required for HCP Vault, omit for local Vault |

For backward compatibility, the script still accepts `USER` and `PASSWORD`. The newer `VAULT_LOGIN_*` names are preferred because they are explicit and less likely to collide with shell defaults.

### Local Docker Vault vs. HCP Vault

The script works with both:

**Local Docker Vault:**
```bash
VAULT_AUTH_METHOD=ldap
VAULT_LOGIN_USERNAME=repping
VAULT_LOGIN_PASSWORD=changeme
VAULT_ADDR=http://127.0.0.1:8200
# No VAULT_NAMESPACE needed
```

**HCP Vault (cloud):**
```bash
VAULT_AUTH_METHOD=userpass
VAULT_LOGIN_USERNAME=repping
VAULT_LOGIN_PASSWORD=changeme
VAULT_ADDR=https://vault.example:8200
VAULT_NAMESPACE=admin/repping-ns
```

HCP Vault requires a **namespace** — a logical isolation boundary within a shared Vault cluster. Think of it as your personal partition of the cloud instance. Without the namespace, your API calls would hit the wrong scope and fail.

---

## What the script does — step by step

### Helper functions

```bash
shell_escape() { printf '%q' "$1"; }
```

Uses `printf '%q'` to safely quote a string for shell output. This ensures that values containing spaces, special characters, or quotes in `VAULT_ADDR` or `VAULT_TOKEN` are written as valid shell syntax in the `export` statements.

```bash
supports_color() { [[ -t 2 && -z "${NO_COLOR:-}" ]]; }
style()  { ... printf '\033[%sm%s\033[0m' ... }
info()   { printf '%s %s\n' "$(style '36' '==>')" "$*" >&2; }
success(){ printf '%s %s\n' "$(style '32' 'OK ')" "$*" >&2; }
error()  { printf '%s %s\n' "$(style '31' 'ERR')" "$*" >&2; }
```

Coloured output helpers. All status messages (`info`, `success`, `error`) go to **stderr** — this is intentional. In `eval` mode, stdout is captured by the calling shell and must contain only the `export` lines. Mixing status messages into stdout would cause `eval` to try to run them as commands, which would fail. Sending them to stderr keeps them visible to the user without polluting the captured output.

### `is_sourced` — detecting how the script was called

```bash
is_sourced() {
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    [[ "${ZSH_EVAL_CONTEXT:-}" == *file* ]]
    return
  fi
  if [[ -n "${BASH_VERSION:-}" ]]; then
    [[ "${BASH_SOURCE[0]}" != "$0" ]]
    return
  fi
  return 1
}
```

This function detects whether the script is being sourced or executed. The technique differs by shell:

- **Bash:** `${BASH_SOURCE[0]}` is the script's path; `$0` is the running command. When sourced, they differ. When executed, they are the same.
- **Zsh:** `${ZSH_EVAL_CONTEXT}` contains `file` when the code is being read from a file (sourced), not when it is the main script.

The result of `is_sourced` controls whether variables are exported directly (sourced) or printed as `export` statements (executed).

### Finding the env file

```bash
if [[ -f "${script_dir}/../data/.vault.env" ]]; then
  env_file="${script_dir}/../data/.vault.env"
elif [[ -f "${PWD}/data/.vault.env" ]]; then
  env_file="${PWD}/data/.vault.env"
fi
```

Looks in two places, in order:

1. Relative to the script's own location (`scripts/../data/.vault.env`) — works when you run the script from any directory
2. Relative to the current working directory (`./data/.vault.env`) — works when you source or eval from the project root

If neither exists, the script exits with a clear error.

### Loading credentials

```bash
set -a
. "${env_file}"
set +a
```

`set -a` tells the shell to automatically export every variable that gets assigned. `.` (dot) is the POSIX equivalent of `source` — it reads and executes the env file in the current process. `set +a` turns off auto-export afterwards. The result: all four variables from `.vault.env` are loaded and exported into the local scope.

```bash
vault_login_user="${USER:-}"
vault_login_password="${PASSWORD:-}"
vault_login_namespace="${VAULT_NAMESPACE:-}"
vault_login_addr="${VAULT_ADDR:-}"
```

Values are copied into local variables so they are clearly named and do not leak into the exported environment accidentally. The script prefers `VAULT_LOGIN_USERNAME` / `VAULT_LOGIN_PASSWORD`, then falls back to `VAULT_USERNAME` / `VAULT_PASSWORD`, and finally to the legacy `USER` / `PASSWORD` names.

### Namespace handling

```bash
if [[ -n "${vault_login_namespace}" ]]; then
  export VAULT_NAMESPACE="${vault_login_namespace}"
else
  unset VAULT_NAMESPACE
fi
```

If a namespace is set, export it so Vault CLI calls use it. If it is empty (local Vault), **unset** it entirely — leaving it as an empty string could cause Vault CLI to send an empty namespace header, which some Vault versions interpret differently from no header at all.

### Authenticating

```bash
vault_token="$(
  vault login \
    -token-only \
    -method="${vault_auth_method}" \
    username="${vault_login_user}" \
    password="${vault_login_password}"
)"
```

`vault login -token-only` performs the authentication and prints only the resulting token — none of the surrounding metadata. The token is captured into `vault_token`.

The script accepts two username/password auth methods:

- `ldap`  
  Vault delegates authentication to the configured LDAP directory. This is now the default and matches the workshop's local Vault Enterprise setup.
- `userpass`  
  Vault validates the username and password against Vault's own internal userpass backend.

If you are using the local workshop stack, `ldap` is the correct default unless you have a separate reason to keep a local userpass backend active.

### Output — sourced vs. executed

**When sourced:**
```bash
export VAULT_TOKEN="${vault_token}"
success "Vault authentication succeeded"
info "Address: ${vault_login_addr}"
```

Variables are exported directly. Status messages go to stderr.

**When executed (eval mode):**
```bash
echo "export VAULT_ADDR=$(shell_escape "${vault_login_addr}")"
echo "export VAULT_TOKEN=$(shell_escape "${vault_token}")"
if [[ -n "${vault_login_namespace}" ]]; then
  echo "export VAULT_NAMESPACE=$(shell_escape "${vault_login_namespace}")"
else
  echo "unset VAULT_NAMESPACE"
fi
```

Each line is a shell statement printed to stdout for `eval` to capture and run. Note that `unset VAULT_NAMESPACE` is also printed when no namespace is set — this clears any stale namespace left over from a previous session.

### `finish` — clean exit handling

```bash
finish() {
  local exit_code="$1"
  if is_sourced; then return "${exit_code}"; else exit "${exit_code}"; fi
}
```

When sourced, `exit` would close your entire terminal session — catastrophic. `return` exits only the sourced script's context. This function handles that distinction so the script always exits cleanly regardless of how it was invoked.

---

## Practical usage examples

### Typical session start (sourced)

```bash
cd /path/to/zero_trust
source ./scripts/vault_login.sh
# → OK  Vault authentication succeeded
# → ==> Address: https://...vault.cloud:8200
# → ==> Namespace: admin/repping-ns

vault status          # now works with your personal token
./scripts/setup_vault.sh --verify   # will see VAULT_TOKEN as valid
```

### Typical session start (eval)

```bash
eval "$(./scripts/vault_login.sh)"
vault status
```

### Verify what was set

```bash
echo $VAULT_ADDR
echo $VAULT_TOKEN
echo $VAULT_NAMESPACE
```

### Check token details

```bash
vault token lookup
# Shows: policies, TTL, creation time, entity ID
```

### Check when the token expires

```bash
vault token lookup | grep ttl
```

---

## Comparison: username/password auth vs. other auth methods in this workshop

| Auth method | Script | Who uses it | Credential type |
|-------------|--------|-------------|-----------------|
| Root token | `unseal_vault.sh` | Initial setup | Hardcoded in `init.txt` |
| LDAP | `vault_login.sh` | Humans (directory-backed login) | Username + password via LDAP |
| Userpass | `vault_login.sh` | Humans (Vault-local login) | Username + password |
| AppRole | `setup_vault.sh` phase 03 | Backend service | role_id + secret_id |
| JWT | `setup_vault.sh` phase 04 | Backend (per-user requests) | Keycloak JWT |
| LDAP | `setup_vault.sh` phase 05 | Humans (LDAP-backed) | LDAP username + password |

LDAP is now the primary human-facing method in this workshop. Userpass remains supported, but it is best treated as a compatibility or fallback option when you explicitly want Vault-local users instead of directory-backed identities.

---

## Prerequisites

| Requirement | Why |
|-------------|-----|
| `vault` CLI on PATH | Performs the actual login |
| `data/.vault.env` present | Contains credentials and connection info |
| Selected auth method enabled in Vault | `ldap` or `userpass` must be mounted |
| Your user account available in the chosen auth source | Either LDAP or Vault userpass must know your username |
| HCP Vault: correct namespace | Requests go to the wrong scope without it |

---

## Troubleshooting

**`Vault env file not found`**
Create `data/.vault.env` with your credentials. See the format above. The file must be in the `data/` directory at the project root.

**`USER and PASSWORD must be set`**
Your `.vault.env` file is missing the login credentials. Set `VAULT_LOGIN_USERNAME=` and `VAULT_LOGIN_PASSWORD=`. Legacy `USER=` and `PASSWORD=` still work, but they are no longer the preferred names.

**`Vault ldap login failed for user repping`** or **`Vault userpass login failed for user repping`**
- Wrong password in `.vault.env`
- The configured auth method is not enabled in Vault (`vault auth list`)
- The user account does not exist in the selected auth source
- For HCP Vault: wrong namespace or the user is in a different namespace

**`vault: command not found`**
Install the Vault CLI. See `readme_setup_vault.md` for installation commands.

**Variables not set after running the script**
You ran it as `./scripts/vault_login.sh` instead of sourcing or eval-ing it. Environment variables cannot propagate from a child process to the parent shell — use `source ./scripts/vault_login.sh` or `eval "$(./scripts/vault_login.sh)"`.

**Token expires mid-session**
Re-run the login. Tokens issued via LDAP or userpass have a TTL set by the Vault policy attached to your user. Check the TTL with `vault token lookup | grep ttl`.
