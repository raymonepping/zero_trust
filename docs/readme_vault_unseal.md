# unseal_vault.sh — Vault Unseal Script

**Location:** `scripts/unseal_vault.sh`
**Reads from:** `vault/init.txt`

This script unseals Vault after every container restart. It reads the unseal keys from `vault/init.txt`, applies the first three, and confirms the operation succeeded. It is the first thing you run whenever you bring the stack up.

```bash
./scripts/unseal_vault.sh
```

---

## What "sealed" means — and why it matters

When Vault starts, it is always in a **sealed** state. A sealed Vault:

- Cannot decrypt any of its stored secrets
- Rejects every API request (including `vault status`)
- Cannot issue tokens or credentials

This is intentional. Vault keeps all its data encrypted on disk at all times. The encryption key is called the **master key**, but Vault never stores the master key anywhere. Instead, it stores only the *encrypted* form of it. To decrypt the master key — and therefore to start serving secrets — Vault needs you to provide unseal keys.

Think of it like a safe inside a locked vault: even if someone steals the physical vault (the encrypted storage volume), they still cannot open the safe inside without the combination.

---

## Shamir's Secret Sharing — how the unseal keys work

When Vault was first initialised, it used an algorithm called **Shamir's Secret Sharing** to split the master key into **5 pieces** (key shares). The algorithm is configured with a **threshold of 3** — you need any 3 of the 5 shares to reconstruct the master key.

```
Master key → split into 5 shares (Shamir's algorithm)
                ├── Unseal Key 1
                ├── Unseal Key 2
                ├── Unseal Key 3  ← any 3 of 5 reconstruct the master key
                ├── Unseal Key 4
                └── Unseal Key 5
```

Why 3 of 5 instead of all 5?

- **Redundancy** — if one key holder loses their key, you are not locked out permanently
- **Security** — a single compromised key is not enough to unseal Vault
- **Practicality** — in a real organisation, 5 trusted people hold one key each; any 3 can act together to unseal

Vault's own documentation describes this as a "quorum" — a minimum number of trusted parties who must agree before the vault opens.

> In this workshop, all 5 keys are stored in `vault/init.txt` for convenience. In a real deployment, each key would be distributed to a different trusted person and never stored together.

---

## The `vault/init.txt` file

This file was written when the Vault container first initialised and ran `vault operator init`. It is **gitignored** — you will never accidentally commit it.

```
Unseal Key 1: <unseal-key-1>
Unseal Key 2: <unseal-key-2>
Unseal Key 3: <unseal-key-3>
Unseal Key 4: <unseal-key-4>
Unseal Key 5: <unseal-key-5>

Initial Root Token: hvs.<root-token>

Vault initialized with 5 key shares and a key threshold of 3...
```

The file contains two important things:

| Item | What it is | How it is used |
|------|-----------|----------------|
| Unseal Keys 1–5 | Shamir shares of the master key | `unseal_vault.sh` applies keys 1–3 |
| Initial Root Token | A superuser token with full Vault access | Copied to `.env` as `VAULT_TOKEN` |

---

## What the script does — line by line

### Configuration

```bash
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
INIT_FILE="${SCRIPT_DIR}/../vault/init.txt"
export VAULT_ADDR
```

Sets the Vault address (defaulting to localhost port 8200) and locates `init.txt` relative to the script's own directory. Exporting `VAULT_ADDR` makes it available to all `vault` CLI calls that follow.

### Guard: check init.txt exists

```bash
if [[ ! -f "${INIT_FILE}" ]]; then
  echo "ERROR: init.txt not found at ${INIT_FILE}" >&2
  exit 1
fi
```

Fails immediately with a clear message if the file is missing. Without it there is nothing to parse, so continuing would be pointless.

### Parse keys and root token

```bash
mapfile -t UNSEAL_KEYS < <(grep "^Unseal Key" "${INIT_FILE}" | awk '{print $NF}')
ROOT_TOKEN=$(grep "^Initial Root Token" "${INIT_FILE}" | awk '{print $NF}')
```

- `grep "^Unseal Key"` — finds only lines starting with `Unseal Key`
- `awk '{print $NF}'` — prints the last field on each line (the key value itself)
- `mapfile -t UNSEAL_KEYS` — reads the output into a Bash array, one element per line
- The root token is parsed the same way from the `Initial Root Token` line

After this block, `${UNSEAL_KEYS[0]}` through `${UNSEAL_KEYS[4]}` hold the five keys and `${ROOT_TOKEN}` holds the token.

### Guard: check keys were found

```bash
if [[ ${#UNSEAL_KEYS[@]} -eq 0 ]]; then
  echo "ERROR: No unseal keys found in ${INIT_FILE}" >&2
  exit 1
fi
```

`${#UNSEAL_KEYS[@]}` is the length of the array. If it is zero, the file exists but could not be parsed — possibly corrupted or from a different Vault version.

### Already unsealed check

```bash
SEALED=$(vault status -format=json 2>/dev/null \
  | grep '"sealed"' \
  | awk -F: '{print $2}' \
  | tr -d ' ,') || true
```

`vault status -format=json` returns a JSON object that includes `"sealed": true` or `"sealed": false`. The pipeline extracts just that boolean value.

The `|| true` at the end prevents the script from exiting if `vault status` returns a non-zero code — which it does when Vault is sealed, because a sealed Vault is technically in an error state.

```bash
if [[ "${SEALED}" == "false" ]]; then
  echo "==> Vault is already unsealed."
  exit 0
fi
```

Idempotency check: if Vault is already unsealed, print a confirmation and exit cleanly. Running the script twice is safe.

### Apply the first three keys

```bash
for i in 0 1 2; do
  echo "    Applying key $((i + 1))..."
  vault operator unseal "${UNSEAL_KEYS[$i]}"
done
```

Loops over array indices 0, 1, 2 — the first three keys. Each `vault operator unseal` call submits one key share to Vault. Vault accumulates shares in memory until the threshold is reached, then reconstructs the master key and transitions to unsealed.

> The unseal keys are submitted one at a time by design. In a real deployment, three different people would each run this command with only their own key — no single person ever sees more than one key.

### Confirm success

```bash
SEALED_AFTER=$(vault status -format=json 2>/dev/null \
  | grep '"sealed"' \
  | awk -F: '{print $2}' \
  | tr -d ' ,') || true

if [[ "${SEALED_AFTER}" == "false" ]]; then
  echo "==> Vault is unsealed."
  echo "    Root token: ${ROOT_TOKEN}"
else
  echo "ERROR: Vault is still sealed after applying 3 keys." >&2
  exit 1
fi
```

Checks the seal status again after applying the keys. Prints the root token on success so you can copy it into your environment. Exits with an error if Vault is still sealed — which would indicate a mismatch between the keys and the Vault instance.

---

## Why Vault seals itself again after a restart

The Vault container **does not have `restart: unless-stopped`** set in `docker-compose.yml` (unlike most other services in the stack). Even if it did, every time the Vault process starts from scratch it begins sealed — the master key is only held in memory, never persisted to disk.

This means you must run `unseal_vault.sh` every time:

- The stack is brought down and back up (`docker compose down && docker compose up`)
- The Vault container is restarted (`docker compose restart vault`)
- The container crashes and restarts

The encrypted data on disk (`vault_data` named volume) persists across restarts — you will not lose your secrets. You just need to re-supply the keys so Vault can decrypt them.

---

## The root token — handle with care

The script prints the root token after a successful unseal. You need to copy it into two places:

**1. Your shell environment** (for running `setup_vault.sh`):
```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=hvs.<root-token>
```

**2. Your `.env` file** (for the backend container):
```
VAULT_TOKEN=hvs.<root-token>
```

The `.env` file is gitignored — never commit it.

> **The root token has unlimited access to everything in Vault.** In a real production system you would:
> 1. Use the root token only to complete initial setup
> 2. Create a purpose-limited admin token
> 3. Revoke the root token immediately: `vault token revoke <root-token>`
>
> For this workshop, keeping the root token is fine — but understanding why you would not in production is the lesson.

---

## What Vault's seal status looks like

You can check seal status at any time:

```bash
vault status
```

**Sealed:**
```
Key                Value
---                -----
Seal Type          shamir
Initialized        true
Sealed             true     ← cannot serve requests
Total Shares       5
Threshold          3
Unseal Progress    0/3      ← keys applied so far
```

**After one key applied:**
```
Unseal Progress    1/3      ← one more applied, two to go
```

**Unsealed:**
```
Sealed             false    ← ready to serve
HA Enabled         false
Active Node Address http://127.0.0.1:8200
```

---

## Sequence — typical workshop start

```bash
# 1. Bring up the stack (vault starts sealed)
docker compose up -d

# 2. Unseal Vault — must happen before anything else
./scripts/unseal_vault.sh

# 3. Export credentials for CLI use
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<token printed by unseal script>

# 4. Verify Vault is ready
vault status

# 5. Continue with setup_vault.sh
./scripts/setup_vault.sh --phase 01
```

---

## Prerequisites

| Requirement | Why |
|-------------|-----|
| `vault` CLI on PATH | Submits unseal keys and checks status |
| `vault/init.txt` present | Contains the unseal keys and root token |
| Vault container running | The process must be up to accept unseal operations |

Install Vault CLI on macOS:
```bash
brew tap hashicorp/tap && brew install hashicorp/tap/vault
```

Install on Linux:
```bash
sudo apt-get install -y vault   # requires HashiCorp apt repo
```

---

## Troubleshooting

**`init.txt not found`**
The file at `vault/init.txt` does not exist. This happens if Vault was never initialised — which should not occur in this workshop because the container auto-initialises on first start. If the file is genuinely missing, check whether the `vault_data` Docker volume exists: `docker volume ls | grep vault`. If the volume is empty, bring up the container and check its logs for the init output.

**`Vault is still sealed after applying 3 keys`**
The keys in `init.txt` do not match the running Vault instance. This happens if the `vault_data` volume was deleted and Vault re-initialised — producing new keys — but `init.txt` still contains old ones. Delete `vault/init.txt`, restart the Vault container, and let it write a fresh `init.txt`.

**`connection refused`**
The Vault container is not running. Run `docker compose up -d vault` and try again.

**`vault: command not found`**
The Vault CLI is not installed. See prerequisites above. Note: you need the CLI on your laptop, not just inside Docker — the script runs `vault` commands against the published port 8200.

**Checking Vault container logs:**
```bash
docker logs zero_trust_vault
```

**Manually applying keys one at a time (if the script fails):**
```bash
vault operator unseal <key-1>
vault operator unseal <key-2>
vault operator unseal <key-3>
```
