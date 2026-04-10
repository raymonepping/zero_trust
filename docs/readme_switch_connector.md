# switch_connector.sh — Connector Swap Script

**Location:** `scripts/switch_connector.sh`

This script is the core workshop mechanic. It replaces `backend/connector.js` with a pre-built version representing a different credential strategy, then restarts the backend container so the change takes effect immediately — no image rebuild required.

Each connector type is a self-contained implementation of the same interface (`getCredentials`, `start`). Swapping the file is the only change needed to move between workshop phases.

---

## How it works

`backend/connector.js` is volume-mounted into the backend container. The container runs `nodemon`, which watches for file changes and automatically restarts the Node.js process when it detects one. This means:

```
You run switch_connector.sh
    ↓
Script downloads or copies a new connector.js
    ↓
Script restarts the backend container
    ↓
Backend loads the new connector on startup
    ↓
All subsequent API calls use the new credential strategy
```

The Docker image never changes. The connector swap is purely a file replacement.

---

## Usage

```bash
# Replace the connector and restart
./scripts/switch_connector.sh --replace-with <type>

# List all available connector types
./scripts/switch_connector.sh --list

# Show which connector is currently active
./scripts/switch_connector.sh --current

# Show help
./scripts/switch_connector.sh --help
```

### `--replace-with <type>`

The main command. Replaces `backend/connector.js` with the named connector type and restarts the backend container.

The script first checks for a local copy in `data/connector.<type>.js`. If found, it copies from there (faster, works offline). If not found, it fetches the file from GitHub.

### `--current`

Detects and prints the active connector type by scanning `backend/connector.js` for its `source:` identifier string. Each connector exports a unique source value — the script uses these as fingerprints to determine what is running without needing to inspect the full file.

### `--list`

Prints all valid connector types with a one-line description of each.

---

## The connector progression

Each connector type represents a more secure credential strategy. The workshop walks through them in order — each one addresses a specific weakness in the previous approach.

---

### Phase 1 — `wired`

**How credentials are stored:** Hardcoded directly in the source code.

```bash
./scripts/switch_connector.sh --replace-with wired
```

The simplest possible implementation. Database host, username, and password are literal strings inside `connector.js`. No configuration, no secrets management — just values baked into the code.

**The problem this demonstrates:**
- Credentials are visible to anyone with repository access
- Rotating a password requires a code change and a deployment
- A leaked repository leaks production credentials
- Every environment (dev, staging, prod) shares the same hardcoded values

**Lesson:** Never put credentials in source code. This is Phase 0 — the starting point that shows what *not* to do before showing better alternatives.

---

### Phase 2 — `env`

**How credentials are stored:** In environment variables, read at startup from the `.env` file.

```bash
./scripts/switch_connector.sh --replace-with env
```

The connector reads `process.env.DATABASE_URL` (or individual `POSTGRES_*` variables) at startup. Credentials are no longer in the source code — they live in `.env` which is gitignored.

**The improvement over `wired`:**
- Credentials are not in the repository
- Different `.env` files can be used for different environments
- Rotating a password only requires updating `.env` and restarting — no code change

**The remaining problem:**
- `.env` is a static file on disk — whoever has filesystem access has the credentials
- Credentials do not expire; a leaked `.env` gives permanent access
- No audit trail of who used the credentials or when
- All services sharing the same static credentials cannot be individually revoked

**Lesson:** Environment variables are better than hardcoding but are still static, unaudited, and unrotated. The credential lifecycle is still entirely manual.

---

### Phase 3 — `vault` (KV static secret)

**How credentials are stored:** In HashiCorp Vault's KV v2 secrets engine. The backend reads them from Vault at startup using a Vault token.

```bash
./scripts/switch_connector.sh --replace-with vault
```

Requires: `./scripts/setup_vault.sh --phase 01`

The connector authenticates to Vault using `VAULT_TOKEN` and reads `secret/data/postgres`. The credentials themselves are the same static values — but they now live in Vault, not a file on disk.

**The improvement over `env`:**
- Credentials are centralised in Vault — not scattered across `.env` files on individual machines
- Vault access is authenticated and audited — every read is logged
- Credentials can be updated in Vault and all services pick up the new values on next read
- Vault enforces access control — only services with the right token can read the secret

**The remaining problem:**
- The credentials in Vault are still static — the same username and password rotate only when a human manually updates them
- The backend is using the **root Vault token**, which has unlimited access to everything in Vault
- A compromised token gives an attacker full Vault access, not just DB access

**Lesson:** Moving secrets into Vault adds auditability and centralised control, but static credentials and a root token are still weak points.

---

### Phase 4 — `approle`

**How credentials are stored:** Static Vault KV secret, but the backend now authenticates to Vault using **AppRole** (role_id + secret_id) instead of the root token.

```bash
./scripts/switch_connector.sh --replace-with approle
```

Requires: `./scripts/setup_vault.sh --phase 01` and `--phase 03`

The connector exchanges a `VAULT_ROLE_ID` and `VAULT_SECRET_ID` for a short-lived, scoped Vault token, then uses that token to read `secret/data/postgres`.

**The improvement over `vault`:**
- The backend no longer uses the root token — it has its own identity
- The Vault token issued via AppRole is scoped to `app-policy` only — it cannot read or write anything outside that policy
- Tokens expire (TTL: 1 hour, max: 4 hours) — a stolen token has a limited window of usefulness
- The AppRole credentials (role_id + secret_id) are separate from the root token and can be rotated independently

**The remaining problem:**
- The DB credentials are still static — same username and password until manually changed
- The `secret_id` must be protected; if leaked, an attacker can impersonate the backend

**Lesson:** AppRole replaces the root token with a machine identity. The backend now has least-privilege access to Vault. But the database credentials themselves are still static.

---

### Phase 5 — `approle-dynamic`

**How credentials are stored:** Dynamic — Vault generates a real, time-limited Postgres user on every request (or when the cached credential nears expiry).

```bash
./scripts/switch_connector.sh --replace-with approle-dynamic
```

Requires: `./scripts/setup_vault.sh --phase 02` and `--phase 03`

The connector authenticates to Vault via AppRole to get a scoped token, then calls `database/creds/app-role`. Vault creates a real Postgres user with a random password, a TTL (default 1 hour), and an expiry baked into Postgres (`VALID UNTIL`). The connector caches the credential and reuses it until 75% of the TTL has elapsed, then fetches a fresh one.

**The improvement over `approle`:**
- No static database password exists anywhere — not in Vault, not in `.env`, not in code
- Each credential is unique and time-limited; they expire and are revoked automatically
- A leaked credential is only useful until it expires
- Vault's lease system tracks every issued credential — they can be revoked individually or en masse
- Postgres itself enforces expiry via `VALID UNTIL` — even if Vault's revocation fails, the credential stops working

**The remaining problem:**
- A single shared credential is issued for all backend instances — there is no per-user scoping
- The credential allows full read/write access regardless of who the end user is

**Lesson:** Dynamic credentials eliminate the static password problem entirely. Every credential has a lifecycle, and Vault owns that lifecycle.

---

### Phase 6 — `approle-rotation`

**How credentials are stored:** Dynamic, same as `approle-dynamic`, but with **proactive renewal** — the connector actively renews both the Vault token and the DB credential before they expire, rather than waiting until 75% TTL and re-fetching.

```bash
./scripts/switch_connector.sh --replace-with approle-rotation
```

Requires: `./scripts/setup_vault.sh --phase 02` and `--phase 03`

This connector starts a background `startAutoRenewal()` loop that monitors the Vault token TTL and the DB credential lease. It renews each at 75% of their TTL. If renewal fails (Vault unreachable, token expired), it re-authenticates from scratch using the role_id and secret_id.

**The improvement over `approle-dynamic`:**
- The backend proactively manages credential lifetimes — no sudden credential expiry during a long-running request
- Renewal keeps the same Postgres user alive rather than creating a new one (fewer orphaned users in Postgres)
- Recovery path: if the Vault token expires, the connector re-authenticates automatically without manual intervention
- Explicit lease revocation on shutdown — credentials are cleaned up when the backend stops cleanly

**The remaining problem:**
- Still a single shared AppRole identity — the backend authenticates to Vault as "the backend", not as "Alice" or "Bob"
- All users get credentials with the same level of access regardless of their role

**Lesson:** Proactive rotation makes the credential lifecycle resilient. The backend never operates with an expired credential, and recovery from failure is automatic.

---

### Phase 7 — `agent-dynamic` (Vault Agent)

**How credentials are stored:** Dynamic credentials rendered to a JSON file on disk by **Vault Agent**, which the backend reads directly.

```bash
./scripts/switch_connector.sh --replace-with agent-dynamic
```

Requires: Vault Agent running (`docker compose up vault-agent`) and Vault configured with AppRole + database secrets engine.

Instead of the backend calling Vault directly, **Vault Agent** runs as a sidecar container. It authenticates to Vault via AppRole, fetches `database/creds/app-role`, and renders the credentials to `/vault/secrets/db-creds.json`. The backend simply reads this file.

The `vault-agent-secrets` Docker volume is shared between the `vault-agent` and `backend` containers. Vault Agent renews the credential lease and rewrites the JSON file before the TTL expires.

**The improvement over `approle-rotation`:**
- The backend has zero Vault-specific code — it just reads a JSON file
- All Vault authentication, token renewal, and credential rotation is handled entirely by Vault Agent
- The backend does not need `VAULT_TOKEN` or AppRole credentials — those live in the agent's config, not the application
- Vault Agent is fault-tolerant by design — it handles retries, backoff, and re-authentication automatically
- Separation of concerns: credential management is the agent's responsibility; the backend focuses on business logic

**The file format** (`/vault/secrets/db-creds.json`):
```json
{
  "username": "v-approle-app-role-txFUOq6a4fmaxhWOnRBl-...",
  "password": "...",
  "host":     "db",
  "port":     5432,
  "database": "appdb",
  "lease_id": "database/creds/app-role/...",
  "lease_duration": 3600
}
```

**The remaining problem:**
- All users still get the same credential regardless of their role
- The backend has no awareness of end-user identity when fetching credentials

**Lesson:** Vault Agent offloads all secrets management to a dedicated process. The application becomes a consumer of pre-rendered credentials — it does not need to know anything about Vault.

---

### Phase 8 — `jwt-rotation`

**How credentials are stored:** Dynamic, with the backend authenticating to Vault using the **end user's Keycloak JWT** instead of AppRole credentials.

```bash
./scripts/switch_connector.sh --replace-with jwt-rotation
```

Requires: `./scripts/setup_vault.sh --phase 02` and `--phase 04`, Keycloak running and configured.

The connector receives the user's Keycloak JWT from the incoming API request, presents it to Vault's JWT auth method, and receives a short-lived Vault token (TTL: 15 minutes). It then fetches a dynamic DB credential using that token. The Vault token and DB credential are both renewed proactively at 75% TTL.

**The improvement over `approle-rotation`:**
- The backend authenticates to Vault **as the user**, not as a generic backend service
- The Vault audit log shows which user triggered each credential request — `jwt-repping@my.org`, not just "the backend"
- If a user's access is revoked in Keycloak, their JWT stops being valid and they can no longer obtain Vault tokens
- No AppRole credentials required in the backend environment — the user's JWT is the credential

**The remaining problem:**
- All users still get the same DB credential (`app-role`) regardless of their Keycloak role (`admin`, `support`, `viewer`)
- A viewer and an admin get identical database access

**Lesson:** JWT auth flows the user's identity all the way into Vault. The audit log now reflects human-readable identities, not just service accounts.

---

### Phase 9 — `jwt-roles`

**How credentials are stored:** Dynamic, role-scoped — the JWT role claim (`admin`, `support`, `viewer`) determines which Vault DB role is requested, and therefore which Postgres credential and Row Level Security policy applies.

```bash
./scripts/switch_connector.sh --replace-with jwt-roles
```

Requires: `./scripts/setup_vault.sh --phase 02` and `--phase 04`, Keycloak with LDAP group → role mapping configured.

The connector reads the `roles` claim from the user's Keycloak JWT and maps it to a Vault DB role:

| JWT role claim | Vault DB role | Postgres RLS | Can see |
|---------------|--------------|-------------|---------|
| `viewer` | `viewer-read` | `orders_viewer_policy` | `public` rows only |
| `support` | `support-read` | `orders_support_policy` | `public` + `internal` rows |
| `admin` | `admin-read` | `orders_admin_policy` | All rows |

Each user gets a credential scoped exactly to their role. A viewer's credential cannot be used to access support or admin data — the restriction is enforced at three independent layers: the Vault policy, the Postgres group role grants, and the RLS policy.

**The improvement over `jwt-rotation`:**
- Access is scoped to the individual user's role — not just to "the backend"
- The credential itself is the security boundary — a viewer cannot escalate even with a bug in the application
- Defense in depth: Vault policy + Postgres grants + RLS all independently enforce the same access boundary

**The remaining problem:**
- All access is still read-only — there is no mechanism for elevated write access when a legitimate write operation is needed
- Granting write access would require either a broader credential for all users or a completely separate authentication step

**Lesson:** Role-scoped credentials make access control data-driven and user-specific. The security boundary is the credential itself, not just application-level checks.

---

### Phase 10 — `jwt-ciba`

**How credentials are stored:** Read credentials are role-scoped dynamic (same as `jwt-roles`). Write credentials (`support-write`) are additionally gated behind **explicit user approval via CIBA** — a separate backchannel authentication step.

```bash
./scripts/switch_connector.sh --replace-with jwt-ciba
```

Requires: `./scripts/setup_vault.sh --phase 02` and `--phase 04`, `./scripts/setup_ciba.sh`, `./scripts/setup_ciba_keycloak.sh`, Keycloak started with the CIBA SPI argument.

For read operations, this connector behaves identically to `jwt-roles`. For write operations (updating order status), the following flow is required:

```
1. User triggers an order update in the frontend
2. Backend initiates a CIBA request with Keycloak:
   "Please authenticate repping for: Approve order #42 → shipped"
3. User sees an approval prompt and explicitly approves
4. Backend receives approval, fetches a support-write credential from Vault
   (TTL: 5 minutes — intentionally very short)
5. Backend performs the UPDATE, then immediately revokes the credential lease
6. Full audit trail in Vault: who requested, which credential, when revoked
```

**The improvement over `jwt-roles`:**
- Write access requires a second explicit authentication step — the user must actively approve each write action
- Write credentials are separate, narrower, and shorter-lived than read credentials
- A compromised backend token cannot perform writes without triggering a user-visible approval request
- The full lifecycle (request → approval → credential → action → revocation) is logged in Vault's audit log

**This is the most secure pattern in the workshop:**
- Reads: role-scoped, dynamic, 1-hour TTL
- Writes: role-scoped, dynamic, 5-minute TTL, require explicit approval, immediately revoked after use

**Lesson:** CIBA introduces a human approval gate between credential issuance and write access. Elevated operations require active consent, not just possession of a valid token.

---

## The full progression at a glance

```
Phase 1  wired            Hardcoded credentials in source code
    ↓    (remove secrets from code)
Phase 2  env              Credentials in environment variables
    ↓    (centralise and audit secret storage)
Phase 3  vault            Static secret in Vault KV — audited, centralised
    ↓    (replace root token with machine identity)
Phase 4  approle          AppRole auth → scoped Vault token → static KV secret
    ↓    (eliminate the static database password)
Phase 5  approle-dynamic  AppRole auth → dynamic DB credential (TTL: 1h)
    ↓    (add proactive renewal and fault tolerance)
Phase 6  approle-rotation AppRole auth → dynamic credential + auto-renewal
    ↓    (offload all Vault interaction to a sidecar)
Phase 7  agent-dynamic    Vault Agent renders credentials to file; backend reads file
    ↓    (flow end-user identity into Vault)
Phase 8  jwt-rotation     Keycloak JWT → Vault token → dynamic credential + renewal
    ↓    (scope the credential to the user's role)
Phase 9  jwt-roles        Keycloak JWT + role claim → role-scoped dynamic credential
    ↓    (gate write access behind explicit user approval)
Phase 10 jwt-ciba         Role-scoped reads + CIBA-approved writes
```

---

## How connector detection works (`--current`)

Each connector exports a unique `source:` string. The `--current` command scans `backend/connector.js` for these fingerprints:

| Connector | Detected by |
|-----------|------------|
| `wired` | `source: "static-config"` |
| `env` | `source: "env-file"` |
| `vault` | `source: "vault-kv"` |
| `dynamic` | `source: "vault-dynamic"` |
| `approle` | `source: "vault-approle"` |
| `approle-dynamic` | `source: "vault-approle-dynamic"` (no `startAutoRenewal`) |
| `approle-rotation` | `source: "vault-approle-dynamic"` + `startAutoRenewal` present |
| `jwt-rotation` | `source: "vault-jwt-dynamic"` (no `VAULT_ROLE_MAP`) |
| `jwt-roles` | `source: "vault-jwt-dynamic"` + `resolveVaultRole` or `VAULT_ROLE_MAP` present |
| `jwt-ciba` | `getWriteCredentials` or `support-write` present |

The `agent-dynamic` connector is detected via `source: "vault-dynamic-agent"` — it shares the Vault dynamic approach but reads from the Vault Agent rendered file rather than calling Vault directly.

---

## How connector files are sourced

The script checks for a local file first, then falls back to GitHub:

```bash
local local_file="${REPO_ROOT}/data/connector.${mode}.js"

if [[ -f "${local_file}" ]]; then
  cp "${local_file}" "${TARGET_FILE}"
else
  curl -fsSL "${BASE_URL}/connector.${mode}.js" -o "${TARGET_FILE}"
fi
```

This means:
- Local files in `data/` take precedence over the remote version — useful for custom or modified connectors
- The script works offline if all connector files are present locally
- Fetching from GitHub requires internet access; if offline, ensure `data/connector.<type>.js` exists

---

## Prerequisites

| Requirement | Why |
|-------------|-----|
| `docker` / `podman` with Compose | Backend container must be running to restart |
| `curl` | Fetches connector from GitHub if not cached locally |
| Stack running | `zero_trust_backend` container must exist |
| Vault unsealed + configured | Required for `vault` and later connectors |
| Keycloak configured | Required for `jwt-*` connectors |
| Vault Agent running | Required for `agent-dynamic` |

---

## Troubleshooting

**`docker compose restart failed — is the stack running?`**
The backend container is not running. Start the full stack first: `docker compose up -d`.

**`Failed to fetch connector — check the URL or your network connection`**
No internet access and no local file in `data/`. Either connect to the internet or ensure `data/connector.<type>.js` exists.

**Backend restarts but behaviour does not change**
Check that nodemon reloaded — look at backend container logs:
```bash
docker logs zero_trust_backend --tail 20
```
If the container restarted but the connector did not change, verify the volume mount is correct in `docker-compose.yml`.

**`--current` shows `unknown`**
The active `connector.js` does not contain any of the known source fingerprints. This can happen with a custom or manually edited connector. Check the file directly:
```bash
grep "source:" backend/connector.js
```

**Connector loads but Vault calls fail**
The required `setup_vault.sh` phases for that connector type have not been run. See the prerequisites for each phase above and run the corresponding `setup_vault.sh` command.
