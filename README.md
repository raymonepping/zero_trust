# Zero Trust Workshop

A hands-on workshop demonstrating progressive credential security patterns using HashiCorp Vault, PostgreSQL, Keycloak, OpenLDAP, Ollama, and a modern React frontend — all orchestrated with Docker Compose.

**Core principle:** applications should never hold long-lived credentials. Credentials are retrieved at runtime from Vault — and as the workshop progresses, become dynamically generated, short-lived, automatically rotated, and backed by federated identity.

---

## Architecture

```
┌──────────────┐   /api/*    ┌──────────────┐    SQL     ┌──────────────┐
│   Frontend   │ ──────────► │   Backend    │ ─────────► │  PostgreSQL  │
│ React / Vite │             │  Express.js  │            │   (appdb)    │
└──────────────┘             └──────┬───────┘            └──────────────┘
                                    │
                   ┌────────────────┼────────────────┐
                   │                │                │
            ┌──────▼──────┐  ┌──────▼──────┐  ┌──────▼─────┐
            │    Vault    │  │   Ollama    │  │  Keycloak  │
            │  Enterprise │  │  llama3.2   │  │   (OIDC)   │
            └──────┬──────┘  └─────────────┘  └──────┬─────┘
                   │                                 │
            ┌──────▼──────┐                   ┌──────▼──────┐
            │  PostgreSQL │                   │  OpenLDAP   │
            │ DB Engine   │                   │   (users)   │
            └─────────────┘                   └─────────────┘
```

### Network Isolation

| Network | Services | External |
| --- | --- | --- |
| `net-frontend` | frontend, backend | No |
| `net-backend` | backend, frontend | No |
| `net-data` | backend, db, vault, ollama, ldap, keycloak | No |
| `net-egress` | ollama | Yes (model pulls only) |

The frontend cannot reach the database or Vault directly — all access goes through the backend.

---

## Services

| Service | Image | Port | Description |
| --- | --- | --- | --- |
| `frontend` | `repping/zero-trust-frontend` | 5173 | React + Vite UI |
| `backend` | `repping/zero-trust-backend` | 3000 | Express.js API |
| `db` | `postgres:17.4` | 5432 | PostgreSQL database |
| `vault` | `hashicorp/vault-enterprise:1.21.3-ent` | 8200 | Vault Enterprise |
| `ollama` | custom | 11434 | Local LLM (llama3.2) |
| `openldap` | `osixia/openldap:1.5.0` | 1389 | LDAP directory |
| `ldap-admin` | `osixia/phpldapadmin` | 8081 | LDAP web UI |
| `keycloak` | `quay.io/keycloak/keycloak` | 8082 | OIDC identity provider |

---

## Workshop Phases

The workshop progresses through phases of increasing credential security. Each phase is represented by a swappable `connector.js` — switch between them with `./scripts/switch_connector.sh`.

| Phase | Connector | Auth chain | Data access |
| --- | --- | --- | --- |
| 0a | `wired` | Hardcoded credentials in code | Public only |
| 0b | `env` | Credentials from env variables | Public only |
| 1 | `vault` | Vault KV v2 static secret | Public + Internal |
| 2 | `dynamic` | Vault database engine — short-lived creds | Public + Internal |
| 3a | `approle` | AppRole → scoped token → KV creds | Public + Internal + Confidential |
| 3b | `approle-dynamic` | AppRole → scoped token → dynamic creds | Public + Internal + Confidential |
| 4 | `approle-rotation` | AppRole + dynamic creds + proactive rotation at 75% TTL | Public + Internal + Confidential |
| 5 | `jwt-rotation` | Keycloak JWT → Vault token → dynamic creds + rotation | All (including Restricted) |

### Data Classification

Every order and preference row carries a classification label:

| Level | Label | Visible from phase |
| --- | --- | --- |
| 0 | `public` | Any connector |
| 1 | `internal` | Vault KV or higher |
| 2 | `confidential` | AppRole or higher |
| 3 | `restricted` | JWT rotation only |

The backend enforces this at query time — the LLM never receives data it isn't allowed to see.

---

## Getting Started

### Prerequisites

- Docker or Podman with Compose
- `vault` CLI
- `jq`
- A Vault Enterprise license file at `./vault/config/vault.hclic`

### First-time setup

```bash
# 1. Create the audit log directory (Vault writes here)
mkdir -p ./vault/audit
chmod 777 ./vault/audit

# 2. Copy the env template and fill in your values
cp .env.example .env   # or edit .env directly

# 3. Start all services
docker compose up -d

# 4. Unseal Vault (reads keys from vault/init.txt)
./scripts/unseal_vault.sh

# 5. Configure Vault (idempotent — safe to re-run)
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<root-token-from-vault/init.txt>
./scripts/setup_vault.sh

# 6. Seed the database
./scripts/seed_db.sh

# 7. Bootstrap LDAP users
LDAP_HOST=localhost LDAP_PORT=1389 ./scripts/setup_ldap.sh
```

### Subsequent starts

```bash
docker compose up -d
./scripts/unseal_vault.sh
```

---

## Configuration — `.env`

All backend environment variables live in the root `.env` file (gitignored). Docker Compose loads it via `env_file: .env` on the backend service.

```ini
# Backend
NODE_ENV=development
PORT=3000

# Database
DATABASE_URL=postgres://appuser:apppassword@db:5432/appdb

# Ollama
OLLAMA_ADDR=http://ollama:11434

# Vault
VAULT_ADDR=http://vault:8200
VAULT_TOKEN=hvs.xxxx
VAULT_MODE=dynamic
VAULT_DB_ROLE=app-role
VAULT_KV_PATH=secret/data/postgres

# AppRole (phases 3a / 3b / 4)
VAULT_ROLE_ID=<role-id-from-setup_vault.sh>
VAULT_SECRET_ID=<secret-id-from-setup_vault.sh>

# Keycloak JWT (phase 5)
KEYCLOAK_ADDR=http://keycloak:8080
KEYCLOAK_REALM=zero-trust
KEYCLOAK_CLIENT_ID=backend
KEYCLOAK_CLIENT_SECRET=<client-secret-from-keycloak>
KEYCLOAK_USERNAME=repping
KEYCLOAK_PASSWORD=password
VAULT_JWT_ROLE=zero-trust-jwt-lab
```

> `VAULT_ROLE_ID` and `VAULT_SECRET_ID` are printed by `./scripts/setup_vault.sh` at the end of each run.

---

## Switching Connector Phases

```bash
# Show current phase
./scripts/switch_connector.sh --current

# List all available phases
./scripts/switch_connector.sh --list

# Switch to a phase (fetches from GitHub, restarts backend)
./scripts/switch_connector.sh --replace-with jwt-rotation
```

Connectors are fetched from `https://raw.githubusercontent.com/raymonepping/zero_trust/refs/heads/main/data/`.

---

## API Reference

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/` | Health check — DB connectivity |
| `GET` | `/health` | Extended health — DB + Vault status, sealed state |
| `GET` | `/users` | All users |
| `GET` | `/orders` | Orders filtered by current trust level |
| `GET` | `/preferences` | Preferences filtered by current trust level |
| `GET` | `/credentials` | Active credential metadata — source, trust level, classification access, lease info |
| `POST` | `/ask` | Natural language query — context filtered by trust level, streamed Ollama response |

### `/health` response

```json
{
  "status": "ok",
  "db": "connected",
  "vault": {
    "status": "active",
    "ok": true,
    "sealed": false,
    "version": "1.21.3+ent"
  }
}
```

`status` is `"degraded"` when Vault is down but the DB is still reachable — the app continues serving public data.

### `/credentials` response

```json
{
  "source": "vault-jwt-dynamic",
  "trust_level": 3,
  "allowed_classifications": ["public", "internal", "confidential", "restricted"],
  "username": "v-jwt-repp-app-role-xxxx",
  "ttl": 3600,
  "leaseId": "database/creds/app-role/xxxx",
  "lease": { "status": "active", "remainingSec": 3418 },
  "rotations": 1
}
```

---

## Database Schema

```sql
users        -- id, first_name, last_name, email, phone, city, country, joined
orders       -- id, user_id, item, category, quantity, price, ordered_at, classification
preferences  -- id, user_id, category, value, classification
```

### Seeding

```bash
./scripts/seed_db.sh
```

Reads from `./data/users.json` (5 users) and `./data/activity.json` (24 orders, 32 preferences). Truncates and re-seeds on every run — safe for workshop use.

---

## Vault Setup

`./scripts/setup_vault.sh` configures everything idempotently:

1. KV v2 secrets engine + `secret/postgres` static secret
2. Database secrets engine + PostgreSQL connection + `app-role` role (1h TTL)
3. AppRole auth method + `app-policy` + `zero-trust-app` role
4. LDAP auth method + connection to OpenLDAP + `ldap-user` policy + user mapping
5. JWT auth method + Keycloak JWKS config + `zero-trust-jwt-lab` role
6. File audit device at `/vault/audit/vault-audit.log`

Re-running the script is safe — existing resources are skipped, policies are always rewritten with the correct content.

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<root-token>
./scripts/setup_vault.sh
```

### Vault Audit Log

```bash
# Live tail — summarised format
./scripts/audit_log.sh

# Filter by path
./scripts/audit_log.sh --path database/creds

# Filter by operation
./scripts/audit_log.sh --op write

# Last 20 entries, no follow
./scripts/audit_log.sh --lines 20 --no-follow

# Rotate log (moves current file, sends SIGHUP to Vault)
./scripts/rotate_vault_audit.sh
./scripts/rotate_vault_audit.sh --keep 14
```

---

## LDAP Directory

OpenLDAP is pre-populated via `./scripts/setup_ldap.sh` from `./ldap/bootstrap.ldif`.

| User | Password | Group |
| --- | --- | --- |
| `repping` | `password` | developers |
| `depping` | `password` | developers |
| `alice` | `alice123` | developers |
| `bob` | `bob123` | developers |
| `charlie` | `charlie123` | developers |

**Admin UI:** [http://localhost:8081](http://localhost:8081) (login: `cn=admin,dc=my,dc=org` / `admin`)

---

## Keycloak (OIDC / JWT)

Keycloak is used in Phase 5 to issue JWTs that Vault validates before granting a scoped token.

**Admin UI:** [http://localhost:8082](http://localhost:8082) (login: `admin` / `admin`)

**Realm:** `zero-trust`  
**Client:** `backend`

The LDAP federation is configured in Keycloak's user federation settings pointing to `ldap://openldap:389`. After syncing, all LDAP users can authenticate through Keycloak.

### Test JWT login

```bash
# Get a Keycloak JWT
TOKEN=$(curl -s -X POST "http://localhost:8082/realms/zero-trust/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=backend&username=repping&password=password&scope=openid" \
  -d "client_secret=${KEYCLOAK_CLIENT_SECRET}" | jq -r '.access_token')

# Exchange for a Vault token
vault write auth/jwt/login role=zero-trust-jwt-lab jwt="${TOKEN}"
```

---

## Publishing Images

```bash
# Build and push both images (default version: 1.0.0)
./scripts/setup_images.sh

# Custom version
./scripts/setup_images.sh 1.2.0

# Custom version and registry user
./scripts/setup_images.sh 1.2.0 myuser
```

---

## Scripts Reference

| Script | Description |
| --- | --- |
| `./scripts/unseal_vault.sh` | Unseals Vault using Shamir keys from `vault/init.txt` |
| `./scripts/setup_vault.sh` | Configures all Vault engines, auth methods, policies, and audit |
| `./scripts/setup_ldap.sh` | Bootstraps LDAP directory from `ldap/bootstrap.ldif` |
| `./scripts/seed_db.sh` | Seeds users, orders, and preferences from `./data/*.json` |
| `./scripts/switch_connector.sh` | Swaps `backend/connector.js` with a phase-specific version and restarts the backend |
| `./scripts/setup_images.sh` | Builds and pushes Docker images for backend and frontend |
| `./scripts/audit_log.sh` | Tails and filters the Vault audit log |
| `./scripts/rotate_vault_audit.sh` | Rotates the Vault audit log file via SIGHUP |

---

## Security Notes

- `vault/init.txt`, `vault/config/vault.hclic`, `vault/data/`, `vault/audit/`, and `.env` are all gitignored
- TLS is disabled for local development — enable it before any shared or production deployment
- `log_raw=false` on the audit device — secrets are HMAC'd, not logged in plaintext
- The backend HTTP 503s only when the DB is down — Vault unavailability degrades to `public` data access without crashing
- Dynamic credentials are auto-expired by Vault — no manual revocation needed
- The frontend cannot communicate with Vault, the DB, or LDAP directly (internal Docker networks)

---

## License

[GPLv3](LICENSE)
