# From Hardcoded Credentials to Context-Aware Trust

## Building a Workshop That Evolves from Static Secrets to JWT, Dynamic Credentials, and Role-Scoped Database Access

There is a big difference between showing Vault in a demo and teaching people why it matters.

Most demos stop after retrieving a password from Vault KV.

That is useful, but it is only the beginning.

If the application still uses a shared database account, if every user sees the same data, and if the backend still has broad unrestricted access, then the architecture has improved how secrets are stored without fundamentally changing how trust works.

For this workshop, the goal was different.

We wanted participants to walk through the actual journey most organizations face:

- hardcoded credentials
- `.env` files
- Vault KV
- dynamic PostgreSQL credentials
- AppRole authentication
- AppRole with proactive rotation
- JWT-based user identity
- role-scoped database access per authenticated user
- audit logging

By the end of the workshop, participants no longer think of Vault as just a secrets manager.

They start to see it as a trust platform.

---

## The Workshop Architecture

The workshop is intentionally structured so participants can evolve the environment in phases.

The initial environment contains:

- PostgreSQL 17
- Vault Enterprise (Raft, server mode)
- Ollama (llama3.2 + nomic-embed-text)
- Node/Express backend
- React/Vite frontend
- OpenLDAP
- Keycloak

The idea is simple:

1. The frontend sends questions to the backend.
2. The backend retrieves data from PostgreSQL.
3. The backend builds a context payload.
4. Ollama generates a human-readable answer.
5. As the workshop progresses, the trust model behind that flow becomes increasingly sophisticated.

At the start, the backend uses a hardcoded PostgreSQL account.

At the end, the backend dynamically requests database credentials from Vault based on the authenticated user's Keycloak role — and each role gets its own dedicated connection pool, lease, and renewal timer.

---

## The Docker Compose Design

The Compose file is intentionally opinionated.

Several design decisions matter:

- The frontend is isolated on `net-frontend`
- The backend sits between frontend and data services on `net-backend`
- Vault, PostgreSQL, LDAP, Keycloak, and Ollama live on `net-data` — an internal network with no external egress
- Ollama also connects to `net-egress` for model downloads
- The frontend cannot directly reach Vault or PostgreSQL
- Bind mounts are used for backend and frontend so participants can change code live during the workshop without rebuilding images
- Health checks ensure the environment becomes usable in a predictable startup order

This creates an important architectural lesson immediately.

Applications should not talk directly to everything.

The backend becomes the policy enforcement point — the only component allowed to bridge user-facing systems and sensitive data services.

---

## Folder Structure and Why It Matters

The repository is organized so participants can clearly see the separation between concerns.

- `backend/` — Express API, authentication middleware (`auth.js`), connection pool management (`pool-manager.js`), and role mapping (`roleResolver.js`)
- `frontend/` — React/Vite UI that streams `/api/ask`, polls `/api/health` and `/api/credentials`
- `data/` — the different connector implementations and JSON seed data
- `scripts/` — all setup and phase-transition logic
- `vault/` — Vault configuration (Raft HCL) and audit log paths
- `ldap/` — LDAP bootstrap identity data
- `db/` — PostgreSQL Dockerfile

One of the most important folders is `data/`.

It contains multiple connector variants, one per workshop phase:

| Connector | Phase | Trust model |
|---|---|---|
| `connector.wired.js` | 0a | Hardcoded in code |
| `connector.env.js` | 0b | Environment variables |
| `connector.vault.js` | 1 | Vault KV static secret |
| `connector.dynamic.js` | 2 | Vault dynamic DB credentials |
| `connector.approle.js` | 3a | AppRole → dynamic credentials |
| `connector.approle-dynamic.js` | 3b | AppRole → dynamic (with caching) |
| `connector.approle-rotation.js` | 4 | AppRole + proactive renewal at 75% TTL |
| `connector.jwt-rotation.js` | 5 | Keycloak JWT → Vault → dynamic + rotation |
| `connector.jwt-roles.js` | 6 | Keycloak JWT → role-scoped pools per user role |

Each connector is swapped into place using a single command:

```bash
./scripts/switch_connector.sh --replace-with dynamic
```

The script checks `./data/` first and only falls back to GitHub if no local file exists. The backend container uses nodemon with a bind-mounted volume — so swapping the file triggers an immediate hot reload without rebuilding the image.

That progression is what makes the workshop powerful.

---

## Phase 0a: Hardcoded Credentials

The workshop starts with the worst possible pattern.

```js
// connector.wired.js
async function getCredentials() {
  return {
    host: "db",
    port: 5432,
    database: "appdb",
    user: "appuser",
    password: "apppassword",
    source: "static-config",
    path: "hardcoded",
  };
}
```

This is deliberate.

Participants need to see how easy it is to get started with hardcoded credentials.

They also need to see why it is dangerous:

- credentials are visible in source control
- credentials are reused across environments
- the same database identity is shared by everyone
- revocation requires a code change and redeployment
- auditability is nearly impossible

This phase works, but it is fragile.

---

## Phase 0b: Environment Variables

The next step moves credentials into `.env`.

```js
// connector.env.js
return {
  host:     process.env.POSTGRES_DB_HOST || "db",
  user:     process.env.POSTGRES_USER,
  password: process.env.POSTGRES_PASSWORD,
  database: process.env.POSTGRES_DB || "appdb",
  source:   "env-file",
};
```

That is an improvement — secrets are no longer embedded in source code.

But `.env` files are still static. They are copied around, reused, stored in CI pipelines, screenshots, and local machines. The credential itself has no expiration.

If someone steals it, they can often keep using it for months.

This is usually the first important realization for participants:

> Moving a password into an environment variable is not Zero Trust. It is just a different storage location.

---

## Phase 1: Vault KV

Next, the backend retrieves the PostgreSQL credentials from Vault KV v2.

```js
// connector.vault.js
const res = await fetch(`${VAULT_ADDR}/v1/${VAULT_KV_PATH}`, {
  headers: { "X-Vault-Token": VAULT_TOKEN },
});
const secret = (await res.json()).data?.data;

return {
  user:     secret.username,
  password: secret.password,
  source:   "vault-kv",
  path:     VAULT_KV_PATH,
};
```

Now participants see the first major Vault benefit:

- centralized storage with access control
- full audit logging of every read
- easier rotation without touching application code
- environment-specific secrets via different paths

But the PostgreSQL account is still static.

Vault is acting like a secure, auditable password manager. That is valuable — but it is not yet dynamic trust.

---

## Phase 2: Dynamic PostgreSQL Credentials

This is where the workshop becomes more interesting.

Instead of storing a static PostgreSQL password, Vault generates credentials dynamically.

```js
// connector.dynamic.js
const res = await fetch(`${VAULT_ADDR}/v1/database/creds/${VAULT_DB_ROLE}`, {
  headers: { "X-Vault-Token": VAULT_TOKEN },
});
const { username, password } = (await res.json()).data;
// username: "v-root-app-role-r6SuYxN2E1QsbUNyFaQv-1775570374"
// TTL: 3600s
```

This changes the operational model completely.

Instead of one shared account:

- every credential is unique
- every credential expires automatically
- credentials can be revoked immediately via the lease ID
- Vault can trace exactly which lease created which database user
- PostgreSQL activity logs become far more meaningful

> This is usually the moment where participants stop thinking about secrets as configuration and start thinking about them as short-lived trust artifacts.

---

## Phase 3: AppRole for Backend Authentication

At this point, the backend is still using `VAULT_TOKEN` — a long-lived root token — to authenticate to Vault. That is not much better than a hardcoded password.

This is where AppRole comes in.

The backend authenticates using a `role_id` and `secret_id` — neither of which is a long-lived token:

```js
// connector.approle.js
const res = await fetch(`${VAULT_ADDR}/v1/auth/approle/login`, {
  method:  "POST",
  headers: { "Content-Type": "application/json" },
  body:    JSON.stringify({ role_id: VAULT_ROLE_ID, secret_id: VAULT_SECRET_ID }),
});
const token = (await res.json()).auth?.client_token;
// short-lived, scoped to app-policy only
```

This is an important lesson because the backend is not a human user. It is a workload.

Workloads need workload identities.

AppRole is simple, predictable, and scoped — the token it issues only has access to the specific paths the `app-policy` permits.

---

## Phase 4: Proactive Rotation

AppRole combined with dynamic credentials is a solid machine-to-machine trust path. But credentials still expire — and a backend that waits until expiry to rotate will eventually fail a live request.

Phase 4 adds proactive renewal at 75% of TTL:

```
Startup → fetch credentials → schedule renewal at 2700s (75% of 3600s TTL)
At 2700s → fetch new credentials → emit rotation event → pool-manager swaps connection pool
```

The renewal timer is registered with `unref()` so it does not prevent Node from exiting cleanly on shutdown.

If proactive renewal fails, a backoff retry sequence fires at 5s, 10s, 30s, and 60s intervals.

A reactive path also exists: if a database query fails with a PostgreSQL auth error code (`28P01`, `28000`, `08006`), `pool-manager.js` immediately triggers a forced credential rotation and retries the query — all transparently to the caller.

---

## Phase 5 & 6: JWT and Keycloak

After the backend identity is established, the next question becomes:

**What about the human user?**

The `setup_keycloak.sh` script creates the required realm, roles, groups, and users.

The `auth.js` middleware validates Bearer JWTs from the frontend. The `roleResolver.js` file maps Keycloak roles to Vault database roles:

```js
// roleResolver.js
viewer  → viewer-read
support → support-read
admin   → admin-read
```

In `connector.jwt-roles.js`, the backend no longer requests a single shared credential. Instead, it maintains **three separate connection pools** — one per Vault DB role — each with its own lease, renewal timer, and rotation lifecycle:

```
startup:
  Keycloak JWT → Vault JWT login → fetch viewer-read creds → pool #1
                                 → fetch support-read creds → pool #2
                                 → fetch admin-read creds  → pool #3

per request:
  user JWT role claim → resolveVaultRole() → route to correct pool
```

The backend log at Phase 6 startup looks like this:

```
[info] Connector mode: vault
[info] Keycloak JWT obtained {"expires_in":300}
[info] Vault JWT login OK {"ttl":900,"role":"zero-trust-jwt-lab"}
[info] Dynamic credentials issued {"role":"viewer-read","user":"v-jwt-repp-viewer-r-...","ttl":3600}
[info] Dynamic credentials issued {"role":"support-read","user":"v-jwt-repp-support--...","ttl":3600}
[info] Dynamic credentials issued {"role":"admin-read","user":"v-jwt-repp-admin-re-...","ttl":3600}
[info] Auto-renewal started {"roles":3,"of":3}
[info] Pool manager initialized {"pools":3}
[info] Backend listening {"port":"3000","mode":"vault"}
```

The system is no longer asking: *"Can the backend access the database?"*

It is asking: *"Can this user, through this backend, with this role, access this data?"*

That is a much stronger trust model.

---

## PostgreSQL Roles and Grants

JWT-based role mapping is only useful if the PostgreSQL roles behind it are designed correctly.

Vault generates ephemeral users and grants them membership in predefined PostgreSQL group roles:

```sql
-- Created once by setup_vault.sh --phase 02
CREATE ROLE "viewer-read"  NOLOGIN;
CREATE ROLE "support-read" NOLOGIN;
CREATE ROLE "admin-read"   NOLOGIN;

GRANT SELECT ON users TO "viewer-read";
GRANT SELECT ON users, orders, preferences, training, tickets, projects TO "support-read";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "admin-read";
```

Vault's creation statement for the `viewer-read` DB role:

```sql
CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}'
  VALID UNTIL '{{expiration}}' IN ROLE "viewer-read";
```

The ephemeral user inherits permissions from the group role and expires automatically.

This also teaches participants a critical nuance:

> Vault does not magically create table permissions. The PostgreSQL group role itself must already have the required grants — Vault only creates the login user and assigns role membership.

---

## Trust Level and Data Classification

The workshop also uses a trust level system layered on top of the credential source.

`server.js` maps each `source` value to a trust level:

```js
const TRUST_LEVELS = {
  "static-config":         0,  // hardcoded / env
  "env-file":              0,
  "vault-kv":              1,
  "vault-dynamic":         1,
  "vault-approle":         2,
  "vault-approle-dynamic": 2,
  "vault-jwt-dynamic":     3,  // most trusted
};
```

Database rows carry a `classification` column (`public`, `internal`, `confidential`, `restricted`).

SQL queries filter on `classification IN (...)` based on the current trust level — so a `static-config` backend can only see `public` data, while a `vault-jwt-dynamic` backend can see all four classifications.

This means the data visible in the frontend changes automatically as participants progress through the connector phases — without any frontend code changes.

---

## The Supporting Scripts

A major strength of the workshop is that nearly everything is automated.

The `scripts/` folder contains:

| Script | Purpose |
|---|---|
| `setup_vault.sh` | Phase-by-phase Vault configuration |
| `setup_keycloak.sh` | Realm, clients, roles, users |
| `setup_ldap.sh` | LDAP identity provisioning |
| `seed_db.sh` | Load users, orders, and other data |
| `switch_connector.sh` | Swap connector and restart backend |
| `unseal_vault.sh` | Unseal Vault after restart |
| `test_routes.sh` | Validate all API endpoints |

`setup_vault.sh` now accepts `--phase` to run only the steps needed for the current connector:

```bash
./scripts/setup_vault.sh --phase 01   # KV + static secret       → connector: vault
./scripts/setup_vault.sh --phase 02   # DB engine + roles         → connector: dynamic, approle*
./scripts/setup_vault.sh --phase 03   # AppRole                   → connector: approle*
./scripts/setup_vault.sh --phase 04   # JWT / Keycloak            → connector: jwt-rotation, jwt-roles
./scripts/setup_vault.sh --phase 05   # LDAP                      → optional lab
./scripts/setup_vault.sh --phase 06   # Audit logging             → optional
./scripts/setup_vault.sh --phase all  # Everything in order
```

Because each phase is idempotent, participants can safely rerun steps without damaging the environment.

---

## Why the Workshop Works

The workshop works because participants can feel the progression.

They are not simply told that Vault is better.

They experience why it is better.

They see the weaknesses of hardcoded credentials.

They see the limitations of `.env` files.

They see why static Vault KV secrets are not enough.

They see why dynamic credentials matter.

They see how JWT changes the trust model.

They see how PostgreSQL role grants enforce real access boundaries.

By the end, the environment has evolved from:

```js
user: "appuser",
password: "apppassword"
```

into something far more sophisticated:

- Keycloak machine identity for the backend service
- Keycloak human identity for each end user
- Short-lived Vault tokens (15 minute TTL)
- Ephemeral PostgreSQL users (1 hour TTL, proactively renewed at 45 minutes)
- Three isolated connection pools — one per user role
- Classification-based data filtering at query time
- Full Vault audit logging of every credential issuance and lease lifecycle

That is the difference between protecting a secret and building trust.

---

## Final Thought

Most organizations do not jump directly from hardcoded passwords to fully dynamic architectures.

They evolve.

That is why the workshop matters.

It gives participants a realistic path they can recognize from their own environments.

It starts with the insecure patterns they already know.

Then it gradually introduces better ways of thinking:

- machine identity
- human identity
- least privilege
- short-lived credentials
- contextual access
- role-level enforcement
- auditability

Vault becomes more than a secret store.

JWT becomes more than a login token.

PostgreSQL becomes more than a database.

Together, they become a trust system.

And that is where Zero Trust becomes real.

---

*🧠 Born from How I Use AI as My DevOps Copilot*
*🤖 Powered by Sally — my AI DevOps copilot*
*🚀 Because automation should automate itself.*
