# Zero Trust Workshop

A hands-on workshop environment demonstrating zero trust principles using HashiCorp Vault, PostgreSQL, Ollama, and a modern React frontend — all orchestrated with Docker Compose.

The core idea: applications should never hold long-lived credentials in config files or environment variables. Instead, credentials are retrieved at runtime from Vault — and eventually generated dynamically per request.

---

## Architecture

```
┌─────────────┐     /api/*      ┌─────────────┐     SQL      ┌──────────────┐
│   Frontend  │ ──────────────► │   Backend   │ ───────────► │  PostgreSQL  │
│  React/Vite │                 │  Express.js │              │   (appdb)    │
└─────────────┘                 └──────┬──────┘              └──────────────┘
                                       │
                              ┌────────┴────────┐
                              │                 │
                         ┌────▼────┐      ┌─────▼──────┐
                         │  Vault  │      │   Ollama   │
                         │  (KV)   │      │  llama3.2  │
                         └─────────┘      └────────────┘
```

---

## Services

### Frontend — `./frontend`

A React 19 + Vite 6 single-page application.

- **Port:** `5173`
- **Features:**
  - Live PostgreSQL connection indicator (green/red pulsing dot)
  - Live Vault credential indicator (yellow pulsing dot) — shows the KV path and username being used
  - Natural language Q&A panel backed by Ollama with suggestion chips and streaming responses
- **Proxy:** All `/api/*` requests are proxied to the backend at `http://backend:3000`

```bash
# Rebuild after source changes
docker-compose up -d --build frontend
```

---

### Backend — `./backend`

A Node.js + Express 5 REST API.

- **Port:** `3000`
- **Hot reload:** nodemon watches for file changes — no rebuild needed during development
- **Key file:** `connector.js` — the swappable credential provider (see below)

#### API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Returns `{ db: "connected" }` |
| `GET` | `/users` | All users |
| `GET` | `/orders` | All orders joined with user names |
| `GET` | `/preferences` | All preferences joined with user names |
| `GET` | `/credentials` | Fetches DB credentials from Vault via `connector.js` |
| `POST` | `/ask` | Sends a question to Ollama with DB context; streams the response |

#### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | — | Full Postgres connection string |
| `VAULT_ADDR` | `http://vault:8200` | Vault server address |
| `VAULT_TOKEN` | — | Vault token (loaded from root `.env`) |
| `VAULT_KV_PATH` | `secret/data/postgres` | KV v2 path for DB credentials |
| `OLLAMA_ADDR` | `http://ollama:11434` | Ollama server address |

---

### connector.js — the swappable credential provider

`./backend/connector.js` is volume-mounted into the container. Edit it locally and the backend hot-reloads automatically — no rebuild needed.

**Phase 1 (current):** reads static credentials from Vault KV v2

```js
// Returns credentials from Vault KV at VAULT_KV_PATH
async function getCredentials() { ... }
```

**Phase 2 (next):** replace the body of `getCredentials()` to call the Vault database secrets engine and receive short-lived, auto-rotated credentials instead.

To seed the KV secret:

```bash
vault kv put secret/postgres \
  username=appuser \
  password=apppassword \
  host=db \
  port=5432 \
  database=appdb
```

---

### Database — `./db`

PostgreSQL 17 with a custom Dockerfile that auto-runs `seed.sql` on first start.

- **Port:** `5432`
- **Database:** `appdb`
- **Credentials:** `appuser` / `apppassword`
- **Persistence:** `db_data` named volume

#### Schema

```sql
users        -- id, first_name, last_name, email, city, country, joined
orders       -- id, user_id, item, category, quantity, price, ordered_at
preferences  -- id, user_id, category, value
```

#### Seeding

```bash
./scripts/seed_db.sh
```

Reads from `./data/users.json` and `./data/activity.json`. Idempotent — safe to run multiple times.

---

### Vault — HashiCorp Vault Enterprise

- **Port:** `8200`
- **UI:** http://localhost:8200/ui
- **Config:** `./vault/config.hcl` (Raft storage, TLS disabled for local dev)
- **License:** `./vault/config/vault.hclic`

Vault starts **sealed** after every container restart. Unseal with:

```bash
./scripts/unseal_vault.sh
```

The script reads unseal keys from `./vault/init.txt` (gitignored) and applies the first 3 of 5 Shamir keys automatically.

The root token is stored in `.env` (gitignored) and referenced in docker-compose as `${VAULT_TOKEN}`.

#### Enable KV secrets engine (first time only)

```bash
vault secrets enable -path=secret kv-v2
```

---

### Ollama — `./ollama`

Local LLM inference server.

- **Port:** `11434`
- **Models:**
  - `llama3.2` (3B) — chat model used by the `/ask` endpoint
  - `nomic-embed-text` — embedding model (ready for RAG in a later phase)
- **Persistence:** `ollama_data` named volume — models survive container rebuilds

Models are pulled automatically on first start. Subsequent starts skip the download.

> Ollama requires at least **4 GB of memory** allocated to the container runtime.
> With Podman: `podman machine set --memory 6144 && podman machine start`

---

## Getting Started

### Prerequisites

- Docker or Podman (with Compose)
- `vault` CLI (for setup commands)
- `jq` (for the seed script)

### First-time setup

```bash
# 1. Start all services
docker-compose up -d

# 2. Unseal Vault
./scripts/unseal_vault.sh

# 3. Enable KV secrets engine
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<root-token-from-vault/init.txt>
vault secrets enable -path=secret kv-v2

# 4. Write DB credentials to Vault
vault kv put secret/postgres \
  username=appuser password=apppassword \
  host=db port=5432 database=appdb

# 5. Seed the database
./scripts/seed_db.sh
```

### Subsequent starts

```bash
docker-compose up -d
./scripts/unseal_vault.sh
```

---

## Development

The backend uses **nodemon** for hot reload. Edit any file in `./backend/` and the server restarts automatically — no `docker-compose up --build` needed.

`connector.js` is volume-mounted separately, meaning you can swap the credential strategy without touching the rest of the backend.

---

## Scripts

| Script | Description |
|--------|-------------|
| `./scripts/unseal_vault.sh` | Unseals Vault using keys from `vault/init.txt` |
| `./scripts/seed_db.sh` | Seeds users, orders, and preferences from JSON files in `./data/` |

---

## Security Notes

- `vault/init.txt`, `vault/config/vault.hclic`, `vault/data/`, and all `.env` files are gitignored
- The Vault token is passed via the root `.env` file and referenced as `${VAULT_TOKEN}` in docker-compose — never hardcoded
- TLS is disabled for local development only — enable it before any production or shared deployment

---

## License

[GPLv3](LICENSE)
