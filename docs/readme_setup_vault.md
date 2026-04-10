# setup_vault.sh — Vault Configuration Script

**Location:** `scripts/setup_vault.sh`

This script configures HashiCorp Vault for the zero trust workshop, phase by phase. Each phase unlocks a new connector type and demonstrates a more secure credential pattern. You run one phase at a time as you progress through the workshop — or run `--phase all` to set everything up at once.

---

## Before you run anything — Vault must be unsealed

Vault starts **sealed** after every container restart. A sealed Vault refuses all requests — it holds encrypted data but cannot decrypt it yet. Before running any phase of this script, unseal Vault first:

```bash
./scripts/unseal_vault.sh
```

This script reads `vault/init.txt` (generated when Vault first initialised) and applies the first three of five unseal keys. Vault uses [Shamir's Secret Sharing](https://en.wikipedia.org/wiki/Shamir%27s_secret_sharing) — you need at least three keys to reconstruct the master key. The file looks like:

```
Unseal Key 1: ijIOsMNVXMBk4HoUTYk...
Unseal Key 2: kCY6ffjVt3ris/K3JvC...
...
Initial Root Token: hvs.XXXXXXXXXXXXXXXX
```

> **Why does Vault seal itself?** Security. If someone steals the encrypted storage, they still cannot read secrets without the unseal keys. Sealing is a deliberate protection — it forces a conscious re-authorisation before Vault serves any data.

---

## Setting your environment

`setup_vault.sh` requires two environment variables before it runs anything:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<root-token-from-vault/init.txt>
```

The root token is printed by `unseal_vault.sh` and is also the last line of `vault/init.txt`. Copy it into your `.env` file as `VAULT_TOKEN` — the backend containers also read it from there.

> **Root token vs. scoped tokens:** The root token has unlimited access to everything in Vault. It is fine for initial setup in a workshop environment, but a real production system would immediately revoke the root token after bootstrapping and use purpose-limited tokens for all ongoing operations. Phase 03 of this script sets up exactly that pattern.

---

## Commands

```bash
./scripts/setup_vault.sh --phase <01|02|03|04|05|06|all>   # run a phase
./scripts/setup_vault.sh --list                             # show all phases
./scripts/setup_vault.sh --verify                          # pre-flight check
./scripts/setup_vault.sh --help                            # full usage
```

### `--verify`

Runs a pre-flight check before you commit to any phase:

- `VAULT_ADDR` and `VAULT_TOKEN` are set
- `vault` CLI is on PATH
- `psql` is available (needed for phase 02)
- Vault is actually reachable at the configured address
- The token is valid

Run this first if anything seems wrong.

---

## Phase overview

| Phase | What it sets up | Unlocks connector |
|-------|----------------|-------------------|
| `01` | KV v2 secrets engine + static Postgres secret | `vault` |
| `02` | Database secrets engine + scoped Postgres roles + Vault DB roles | `dynamic`, `approle*`, `jwt*` |
| `03` | AppRole auth + `app-policy` + `zero-trust-app` role | `approle`, `approle-dynamic`, `approle-rotation` |
| `04` | JWT auth (Keycloak) + `zero-trust-jwt-lab` policy + role | `jwt-rotation`, `jwt-roles` |
| `05` | LDAP auth + `ldap-user` policy + user mapping | optional lab |
| `06` | Audit logging to file | optional |
| `all` | All phases in order | everything |

Phases build on each other — run them in order. Phase 02 depends on the database engine which must have a connection to Postgres, so `psql` must be installed on your machine.

---

## Phase 01 — KV v2 Secrets Engine

**Connector unlocked:** `vault`

### What is KV v2?

KV (Key-Value) v2 is Vault's simplest secrets engine — a versioned key-value store. You write a secret in, you read it back out. Version 2 keeps a history of every value written to a path, so you can see previous values and roll back if needed.

### What this phase does

```bash
vault secrets enable -path=secret kv-v2
```

Mounts the KV v2 engine at the path `secret/`. All secrets stored here will be addressable as `secret/<name>`.

```bash
vault kv put secret/postgres \
  username=appuser \
  password=apppassword \
  host=db \
  port=5432 \
  database=appdb
```

Writes the Postgres connection details as a single secret at `secret/postgres`. The backend's `vault` connector reads this path and uses the values to connect to the database.

### The security improvement over hardcoding

| Approach | Where credentials live |
|----------|----------------------|
| Hardcoded (`wired` connector) | In the source code — visible to anyone with repo access |
| Environment variables (`env` connector) | In `.env` — slightly better, but still a static file |
| **KV v2 (`vault` connector)** | In Vault — access controlled, audited, versioned |

Credentials are no longer in the codebase at all. The application authenticates to Vault at startup and fetches them on demand.

---

## Phase 02 — Database Secrets Engine

**Connector unlocked:** `dynamic`, `approle`, `approle-dynamic`, `approle-rotation`, `jwt-rotation`, `jwt-roles`

This is the most significant phase. Instead of storing a static password in Vault, Vault now **generates short-lived database credentials on request** and revokes them when they expire.

### How Vault's database secrets engine works

```
Backend requests credentials → Vault creates a real Postgres user → returns username + password
                                        ↓
                              Vault tracks the lease TTL
                                        ↓
                              TTL expires → Vault revokes the user (DROP ROLE)
```

No shared long-lived password exists anywhere. Every credential is unique, time-limited, and tied to a specific lease that Vault can revoke at any time.

### Step 1: Enable the engine

```bash
vault secrets enable database
```

Mounts the database secrets engine at `database/`.

### Step 2: Configure the connection

```bash
vault write database/config/postgres \
  plugin_name=postgresql-database-plugin \
  allowed_roles="app-role,viewer-read,support-read,admin-read" \
  connection_url="postgresql://{{username}}:{{password}}@db:5432/appdb?sslmode=disable" \
  username="appuser" \
  password="apppassword"
```

Teaches Vault how to connect to Postgres. The `{{username}}` and `{{password}}` placeholders are Vault's own templating syntax — Vault replaces them at runtime with the configured credentials.

`allowed_roles` is a safelist — only the named Vault roles can use this connection. Vault refuses to generate credentials for any role not listed here.

### Step 3: PostgreSQL group roles

Before Vault can create scoped users, Postgres needs **group roles** — role templates that define what a class of users is allowed to do. Individual Vault-generated users inherit from these group roles.

```sql
CREATE ROLE "viewer-read"  NOLOGIN;
CREATE ROLE "support-read" NOLOGIN;
CREATE ROLE "admin-read"   NOLOGIN;

GRANT USAGE ON SCHEMA public TO "viewer-read", "support-read", "admin-read";
GRANT SELECT ON users TO "viewer-read";
GRANT SELECT ON users, orders, preferences, training, tickets, projects TO "support-read";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "admin-read";
```

`NOLOGIN` means these group roles cannot connect directly — they are templates only. Vault-generated users log in and inherit the group's permissions via `IN ROLE`.

| Group role | Table access |
|-----------|-------------|
| `viewer-read` | `users` table only + RLS limits orders to `public` rows |
| `support-read` | `users`, `orders`, `preferences`, `training`, `tickets`, `projects` + RLS limits orders |
| `admin-read` | All tables, all rows |

Combined with the Row Level Security policies set up by `seed_db.sh`, this creates a layered access model: table-level grants restrict which tables a role can query, and RLS restricts which rows within those tables are visible.

### Step 4: Vault DB roles

Each Vault DB role defines the SQL that runs when a credential is requested and when it is revoked.

```bash
vault write database/roles/viewer-read \
  db_name=postgres \
  default_ttl="1h" \
  max_ttl="24h" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' \
    VALID UNTIL '{{expiration}}' IN ROLE \"viewer-read\"; \
    GRANT SELECT ON users TO \"{{name}}\";" \
  revocation_statements="REVOKE ALL ...; DROP OWNED BY \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";"
```

Key templating placeholders:

| Placeholder | Replaced with |
|-------------|--------------|
| `{{name}}` | A unique generated username (e.g. `v-approle-viewer-read-abc123`) |
| `{{password}}` | A randomly generated password |
| `{{expiration}}` | The timestamp when the lease expires |

`IN ROLE "viewer-read"` grants the new user all permissions of the `viewer-read` group role. `VALID UNTIL` is a hard expiry baked into Postgres itself — even if Vault's revocation fails, the credential becomes unusable after that time.

The `app-role` is a broader role without group scoping — used by earlier connectors that do not yet distinguish between user roles.

### Smoke test

At the end of phase 02 the script generates a test credential and prints it:

```bash
vault read database/creds/app-role
```

You should see a `username` and `password` printed. That is a real, working Postgres user created live. Check in Postgres with `\du` — you will see it. Wait for the TTL to expire and it will be gone.

---

## Phase 03 — AppRole Auth Method

**Connector unlocked:** `approle`, `approle-dynamic`, `approle-rotation`

### The problem with the root token

Up to this point the backend has been using the root Vault token — an all-powerful credential that can do anything in Vault. This violates the principle of least privilege. If the backend is compromised, an attacker has full Vault access.

AppRole solves this by giving the backend its own identity with a scoped, time-limited token.

### How AppRole works

AppRole is a machine-to-machine authentication method. Instead of a username and password, an application presents two pieces:

- **Role ID** — public identifier, like a username. Not secret.
- **Secret ID** — a one-time or limited-use credential, like a password. Must be protected.

```
Backend             →   Vault
role_id + secret_id →   authenticate
                    ←   scoped token (TTL: 1h, max: 4h)
                    →   use token to read database/creds/app-role
                    ←   dynamic DB credential
```

### What this phase does

**Enables AppRole:**
```bash
vault auth enable approle
```

**Writes the `app-policy`:**
```hcl
path "database/creds/app-role" {
  capabilities = ["read"]
}
path "secret/data/postgres" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
```

This policy is the minimum the backend needs — nothing more. It can read dynamic DB credentials, read the KV secret, and renew its own token. It cannot write secrets, modify Vault config, or access any other path.

**Creates the `zero-trust-app` AppRole:**
```bash
vault write auth/approle/role/zero-trust-app \
  token_policies="app-policy" \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=0 \       # Secret IDs never expire (workshop convenience)
  secret_id_num_uses=0    # Secret IDs can be used unlimited times
```

`token_ttl=1h` means tokens expire after one hour — the backend must renew or re-authenticate. `token_max_ttl=4h` means even a renewed token cannot live longer than four hours from creation.

**Generates credentials and prints them:**

```
VAULT_ROLE_ID=<uuid>
VAULT_SECRET_ID=<uuid>
```

Copy these into your `.env` file. They are what the AppRole connectors use to authenticate to Vault instead of the root token.

> **Secret IDs are sensitive.** The script shows the Secret ID once. In production, Secret IDs would be delivered via a trusted orchestrator (CI/CD, Kubernetes init container) with `secret_id_num_uses=1` so they are consumed on first use and cannot be replayed.

### Smoke test

The script performs a test login using the just-generated credentials and prints the resulting token's policies and TTL, confirming the AppRole works end-to-end.

---

## Phase 04 — JWT Auth Method (Keycloak)

**Connector unlocked:** `jwt-rotation`, `jwt-roles`

### The problem with AppRole in a user-facing context

AppRole is great for machine-to-machine auth. But when individual users log in to the frontend and make API requests, we want the database credential to be scoped to *that user's role* — not a single shared application role. AppRole cannot express per-user identity.

JWT auth solves this: the user's Keycloak JWT is forwarded to Vault, which validates it and issues a Vault token scoped to what that JWT claims.

### How JWT auth works

```
User logs in → Keycloak issues JWT (contains role: "support")
     ↓
Backend receives request with JWT as Bearer token
     ↓
Backend presents JWT to Vault: vault write auth/jwt/login role=zero-trust-jwt-lab jwt=<token>
     ↓
Vault fetches Keycloak's public key (JWKS endpoint) and verifies the JWT signature
Vault checks the token's issuer and audience match the configured values
     ↓
Vault issues a scoped Vault token (TTL: 15 minutes)
     ↓
Backend uses Vault token to request database/creds/support-read
     ↓
Postgres credential scoped to support-read is issued
```

### What this phase does

**Enables JWT auth:**
```bash
vault auth enable jwt
```

**Configures Vault to trust Keycloak:**
```bash
vault write auth/jwt/config \
  jwks_url="http://keycloak:8080/realms/zero-trust/protocol/openid-connect/certs" \
  bound_issuer="http://keycloak:8080/realms/zero-trust"
```

`jwks_url` points to Keycloak's **JSON Web Key Set** endpoint — a public URL where Keycloak publishes its signing keys. Vault fetches this to verify JWT signatures without needing any shared secret.

`bound_issuer` restricts Vault to only accepting JWTs issued by this specific Keycloak realm. A JWT from any other source will be rejected.

**Writes the `zero-trust-jwt-lab` policy:**

This policy grants access to all scoped DB credential paths — `app-role`, `viewer-read`, `support-read`, and `admin-read` — plus token management and lease operations. The connector itself decides which path to use based on the JWT role claim.

**Creates the JWT role:**
```bash
vault write auth/jwt/role/zero-trust-jwt-lab \
  role_type="jwt" \
  bound_audiences="account" \
  bound_issuer="http://keycloak:8080/realms/zero-trust" \
  user_claim="email" \
  token_policies="zero-trust-jwt-lab" \
  token_ttl="15m"
```

`user_claim="email"` — the JWT's `email` claim becomes the Vault token's entity alias (used for auditing). `token_ttl="15m"` — Vault tokens issued via JWT auth are short-lived. The backend re-authenticates with a fresh JWT for each request cycle.

`bound_audiences` must match the `aud` claim in the JWT. Keycloak sets this to `"account"` for tokens issued to the `backend` client.

---

## Phase 05 — LDAP Auth Method (Optional)

This phase is a standalone lab exercise, not required for any connector.

It configures Vault to accept LDAP username/password authentication directly — letting workshop participants log in to Vault as themselves:

```bash
vault login -method=ldap username=repping
```

The LDAP config points at the same OpenLDAP container used by Keycloak, using identical connection parameters. A minimal `ldap-user` policy is created granting read access to `secret/postgres`.

The user `repping` is explicitly mapped to this policy. Other users could be added by mapping them, or by mapping entire LDAP groups.

**Useful for:** demonstrating that humans, not just machines, can authenticate to Vault — and that their access can be scoped just as tightly.

---

## Phase 06 — Audit Logging (Optional but recommended)

```bash
vault audit enable file file_path=/vault/audit/vault-audit.log \
  log_raw=false \
  hmac_accessor=true
```

Enables Vault's file audit device. Every request and response Vault handles is written to this log — who authenticated, what path they accessed, what the result was, and when.

- `log_raw=false` — secret values in responses are **not** written to the log. Only the request metadata is logged.
- `hmac_accessor=true` — token accessors are HMAC-hashed so they cannot be used to look up tokens from the log alone.

The log file is volume-mounted at `vault/audit/` on your host, so you can read it directly:

```bash
cat vault/audit/vault-audit.log | jq .
```

Audit logging is a compliance requirement in most real environments. In this workshop it lets you see every credential request the backend makes, correlate it with a lease ID, and watch revocations happen.

---

## The full privilege progression

Each phase represents a more mature security posture:

```
Phase 01 — Static secret in Vault KV
  ↓ credentials are fixed, but access is controlled and audited

Phase 02 — Dynamic credentials
  ↓ no static password exists; credentials expire automatically

Phase 03 — AppRole (machine identity)
  ↓ the backend has its own scoped identity, not the root token

Phase 04 — JWT auth (user identity flows through)
  ↓ individual user roles drive which DB credential is issued
  ↓ a viewer cannot get a support-read credential, even with the right token

Phase 05 — LDAP auth (human identity in Vault)
  ↓ humans authenticate to Vault directly as themselves

Phase 06 — Audit logging
  ↓ full, tamper-evident record of every secret access
```

---

## How to run it — typical workshop sequence

```bash
# 1. Start the stack
docker compose up -d vault db

# 2. Unseal Vault
./scripts/unseal_vault.sh

# 3. Set your environment
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<root-token-from-vault/init.txt>

# 4. Verify everything is ready
./scripts/setup_vault.sh --verify

# 5. Run phases as you progress through the workshop
./scripts/setup_vault.sh --phase 01   # enables vault connector
./scripts/setup_vault.sh --phase 02   # enables dynamic connector
./scripts/setup_vault.sh --phase 03   # enables approle connectors
./scripts/setup_vault.sh --phase 04   # enables jwt connectors

# Or run everything at once
./scripts/setup_vault.sh --phase all
```

The script is **idempotent** — running a phase twice is safe. Existing engines, roles, and policies are detected and skipped or updated rather than duplicated.

---

## Prerequisites

| Requirement | Phase | Why |
|-------------|-------|-----|
| `vault` CLI on PATH | All | Communicates with the Vault API |
| `VAULT_ADDR` exported | All | Tells the CLI where Vault is |
| `VAULT_TOKEN` exported | All | Authenticates to Vault |
| Vault unsealed | All | A sealed Vault rejects all requests |
| `psql` installed | 02 | Creates Postgres group roles |
| Keycloak running | 04 | Vault fetches JWKS from it |
| OpenLDAP running | 05 | Vault connects to validate credentials |

Install Vault CLI on macOS:
```bash
brew tap hashicorp/tap && brew install hashicorp/tap/vault
```

---

## Troubleshooting

**`VAULT_ADDR and VAULT_TOKEN must be set`**
Export them in your shell before running the script. They are not read from `.env` automatically by the script itself — only by Docker containers.

**`Error making API request: ... connection refused`**
Vault is not running or not reachable. Check `docker compose ps vault` and ensure `unseal_vault.sh` has been run.

**`psql: error: connection to server ... failed`** (phase 02)
The database container is not running or port 5432 is not published. Run `docker compose up -d db` and try again.

**`existing mount at secret/`** or similar
The engine is already enabled — the script detects this and skips. Not an error.

**Phase 04 smoke test fails with JWKS error**
Keycloak is not running or not yet healthy. Run `docker compose up -d keycloak` and wait for its healthcheck to pass before running phase 04.

**Checking what Vault has configured:**
```bash
vault secrets list          # see all mounted secrets engines
vault auth list             # see all enabled auth methods
vault policy list           # see all policies
vault read database/config/postgres   # inspect DB config
```
