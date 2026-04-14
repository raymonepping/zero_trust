# Zero Trust Workshop

Hands-on labs for moving an application from hardcoded credentials to short-lived, role-scoped, user-aware, and approval-gated access patterns using:

- PostgreSQL
- HashiCorp Vault
- Vault Agent
- OpenLDAP
- Keycloak
- a React frontend
- an Express backend
- Docker Compose

The workshop is built around one core idea:

> applications should not hold long-lived secrets, and elevated access should be narrow, auditable, and short-lived.

This repository is not just a demo app. It is a progression of security models that you can switch between live by swapping the backend connector.

For the detailed script and subsystem docs, see [index.md](./index.md).

---

## Table Of Contents

- [What This Workshop Teaches](#what-this-workshop-teaches)
- [Architecture](#architecture)
- [Services](#services)
- [Recommended Lab Path](#recommended-lab-path)
- [Supported Connector Modes](#supported-connector-modes)
- [Getting Started](#getting-started)
- [Phase 0: Start The Lab Without Vault](#phase-0-start-the-lab-without-vault)
- [Progressing Through The Labs](#progressing-through-the-labs)
- [Key URLs](#key-urls)
- [Useful Commands](#useful-commands)
- [Repository Docs](#repository-docs)
- [Operational Notes](#operational-notes)

---

## What This Workshop Teaches

The labs walk students and engineers through these ideas in a concrete way:

- why hardcoded credentials are dangerous
- why `.env` files are only a partial improvement
- how Vault centralizes secret storage
- how AppRole replaces root-token style access with scoped machine identity
- how dynamic database credentials remove the static password problem
- how proactive renewal improves resilience
- how Vault Agent moves credential management out of application code
- how JWT auth flows end-user identity into Vault
- how role-scoped credentials enforce least privilege
- how CIBA adds explicit approval for high-impact writes

The same backend and frontend stay in place throughout. What changes is the credential strategy.

---

## Architecture

The diagrams below reflect the current `docker-compose.yml` relationships, network boundaries, and shared volumes. For the full architectural narrative — including the two access planes and zero-trust principles — see [docs/architecture.md](./docs/architecture.md).

```text
╔══════════════════════════════════════════════════════════════════════════════╗
║  Browser                                                                     ║
╚══════════════════════════════════════╦═══════════════════════════════════════╝
                                       │  HTTP  :8088
                    ┌──────────────────▼──────────────────┐
                    │         Frontend  (React/Vite)      │  net-frontend
                    │              port 8088              │
                    └──────────────────┬──────────────────┘
                                       │  /api/*  :3000
          ╔════════════════════════════╪════════════════════════════╗
          ║  net-backend               │                            ║
          ║           ┌────────────────▼────────────────┐           ║
          ║           │        Backend  (Express)       │           ║
          ║           │           port  3000            │           ║
          ║           └──┬──────┬──────┬──────┬─────────┘           ║
          ╚══════════════╪══════╪══════╪══════╪═════════════════════╝
                         │      │      │      │
          ╔══════════════╪══════╪══════╪══════╪═════════════════════════════════════╗
          ║  net-data    │      │      │      │                                     ║
          ║              │      │      │      │ reads from shared volume            ║
          ║    ┌─────────▼─┐  ┌─▼────┐ │  ┌───▼──────────────────────────────────┐  ║
          ║    │ PostgreSQL│  │Vault │ │  │  vault-agent-secrets  (Docker vol.)  │  ║
          ║    │  (db)     │  │:8200 │ │  └──────────────────────────────────────┘  ║
          ║    │  port5432 │  └──▲───┘ │            ▲ writes                        ║
          ║    └───────────┘     │     │  ┌─────────┴────────┐                      ║
          ║                      │     │  │   Vault Agent    │                      ║
          ║                      │     │  │  (sidecar)       │──► Vault :8200       ║
          ║                      │     │  └──────────────────┘                      ║
          ║                      │     │                                            ║
          ║                      │  ┌──▼───────┐   ┌──────────────┐                 ║
          ║                      │  │ Keycloak │   │  LDAP Admin  │                 ║
          ║                      │  │  :8082   │   │  :8081       │                 ║
          ║                      │  └────┬─────┘   └───────┬──────┘                 ║
          ║                      │       │  CIBA callback  │                        ║
          ║                      │       │  /ciba/request  │                        ║
          ║                      │       ▼                 ▼                        ║
          ║                      │  ┌──────────────────────────┐                    ║
          ║                      │  │     OpenLDAP  :1389      │                    ║
          ║                      │  └──────────────────────────┘                    ║
          ║                      │                                                  ║
          ║              ┌───────▼──────┐                                           ║
          ║              │    Ollama    │                                           ║
          ║              │   :11434     │                                           ║
          ║              └───────┬──────┘                                           ║
          ╚══════════════════════╪══════════════════════════════════════════════════╝
                                 │  model pulls only
          ╔══════════════════════╪══════╗
          ║  net-egress          │      ║
          ║              ┌───────▼────┐ ║
          ║              │  Internet  │ ║
          ║              └────────────┘ ║
          ╚═════════════════════════════╝
```

### Boundary access-control profile — multi-hop architecture

The `access-control` profile adds a three-zone Boundary deployment. SSH sessions are brokered through two worker hops before reaching the protected target — the client never has direct network access to the private network.

```text
  SSH Client / Boundary Desktop App
      │
      │  :9200  authenticate
      │  :9202  SSH proxy (multi-hop)
      │
╔══════════════════════════════════════════════════════════════════════════════╗
║  net-boundary-control  [profile: access-control]                             ║
║                                                                              ║
║  ┌──────────────────┐   ┌────────────────────────────────────────────────┐   ║
║  │  boundary-db     │◄──│  boundary-controller  :9200 api  :9201 cluster │   ║
║  │  (Postgres 16)   │   └────────────────────────────────────────────────┘   ║
║  └──────────────────┘                                                        ║
║                        ┌────────────────────────────────────────────────┐    ║
║                        │  ingress-worker                       :9202    │    ║
║                        └────────────────────────────────────────────────┘    ║
╚══════════════════════════════════════╦═══════════════════════════════════════╝
                                       │  hop 1  (control plane → DMZ)
╔══════════════════════════════════════╩═══════════════════════════════════════╗
║  net-boundary-dmz                                                            ║
║                                                                              ║
║                        ┌────────────────────────────────────────────────┐    ║
║                        │  egress-worker                                 │    ║
║                        └────────────────────────────────────────────────┘    ║
╚══════════════════════════════════════╦═══════════════════════════════════════╝
                                       │  hop 2  (DMZ → private network)
╔══════════════════════════════════════╩═══════════════════════════════════════╗
║  net-boundary-private                                                        ║
║                                                                              ║
║       ┌────────────────────────────────┐    ┌────────────────────────────┐   ║
║       │  boundary-ssh                  │    │  boundary-target           │   ║
║       │  ubuntu-sshd            :22    │    │  nginx              :80    │   ║
║       └────────────────────────────────┘    └────────────────────────────┘   ║
║                                                                              ║
║  db (PostgreSQL :5432) is also on this network (reachable via egress)        ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

### Network isolation

Seven Docker networks enforce strict traffic boundaries. Services can only talk to services on a shared network — there is no cross-network routing. The three `net-boundary-*` networks are only active with the `access-control` profile.

| Network | Services | Purpose |
| ------- | -------- | ------- |
| `net-frontend` | `frontend` | Isolates the UI from everything except the browser |
| `net-backend` | `frontend`, `backend` | The only path from frontend to the API |
| `net-data` | `backend`, `db`, `vault`, `vault-agent`, `ollama`, `openldap`, `ldap-admin`, `keycloak`, `boundary-egress-worker` | All internal service communication; `ldap-admin` is profile-gated (`tools`) |
| `net-egress` | `ollama` | Allows model pulls from the internet; all other services are isolated |
| `net-boundary-control` | `boundary-db`, `boundary-controller`, `boundary-ingress-worker` | Boundary control plane; fully internal |
| `net-boundary-dmz` | `boundary-ingress-worker`, `boundary-egress-worker` | Transit zone between the two worker hops |
| `net-boundary-private` | `boundary-egress-worker`, `boundary-target`, `boundary-ssh`, `db` | Protected network; only the egress worker can reach targets here |

**Key consequences of this model:**

- The **frontend cannot reach PostgreSQL, Vault, OpenLDAP, or Keycloak directly** — all data flows through the backend
- The **backend is the only application boundary** — it owns authentication, authorisation, and credential management
- **Keycloak authenticates users against OpenLDAP**, and reaches back to the backend via `/ciba/request` for CIBA approval delegation
- **Vault Agent and backend share credentials through a Docker named volume** (`vault-agent-secrets`), not an HTTP API — the backend reads a rendered JSON file, never calling Vault directly in the `agent-dynamic` connector phase
- **Boundary enforces zero-trust access to SSH targets** — the client authenticates to the controller, and the session is proxied through ingress → egress workers without the client ever touching `net-boundary-private` directly
- **`db` is dual-homed** on `net-data` and `net-boundary-private` — it is reachable both by the backend (application path) and through Boundary (brokered access path)

---

## Services

| Service | Image / Build | Port | Role |
| ------- | ------------- | ---- | ---- |
| `frontend` | `repping/zero-trust-frontend` | `8088` | React/Vite UI — student interface and CIBA approval flow |
| `backend` | `repping/zero-trust-backend` | `3000` | Express API — connector execution, JWT/CIBA logic, Vault integration |
| `db` | `./db` (Postgres 17) | `5432` | PostgreSQL with RLS policies and dynamic Vault roles; also on `net-boundary-private` |
| `vault` | `hashicorp/vault-enterprise` | `8200` | Secrets engine, auth methods, dynamic credentials, audit log |
| `vault-agent` | `hashicorp/vault-enterprise` | — | Sidecar: authenticates to Vault, renders `db-creds.json` to shared volume |
| `openldap` | `osixia/openldap` | `1389` | User directory — source of truth for identities and group membership |
| `ldap-admin` | `osixia/phpldapadmin` | `8081` | Optional LDAP admin UI, started through the `tools` profile or on demand |
| `keycloak` | `quay.io/keycloak/keycloak` | `8082` | OIDC provider — JWT issuance, role mapping, CIBA backchannel auth |
| `ollama` | `./ollama` | `11434` | Local LLM (llama3.2 + nomic-embed-text) for `/api/ask` |
| `boundary-db` | `postgres:16` | — | Boundary's PostgreSQL backend; stores controller state (`access-control` profile) |
| `boundary-controller` | `hashicorp/boundary-enterprise` | `9200`, `9201` | Boundary control plane — session management, target authorization (`access-control` profile) |
| `boundary-ingress-worker` | `hashicorp/boundary-enterprise` | `9202` | Ingress worker — public-facing proxy entry point; bridges control plane and DMZ (`access-control` profile) |
| `boundary-egress-worker` | `hashicorp/boundary-enterprise` | — | Egress worker — connects from DMZ into the private network to reach targets (`access-control` profile) |
| `boundary-target` | `nginx:alpine` | `80` | Demo HTTP target; reachable only through Boundary egress (`access-control` profile) |
| `boundary-ssh` | `rastasheep/ubuntu-sshd` | `22` | SSH target; reached via Boundary multi-hop proxy (`access-control` profile) |

### Persistent volumes

| Volume | Used by | Contains |
| ------ | ------- | -------- |
| `db_data` | `db` | PostgreSQL data directory |
| `vault_data` | `vault` | Raft storage (secrets, config, audit) |
| `vault-agent-secrets` | `vault-agent`, `backend` | Agent-rendered `db-creds.json` (shared via volume mount) |
| `ollama_data` | `ollama` | Downloaded model weights |
| `openldap-data` | `openldap` | LDAP directory entries |
| `openldap-config` | `openldap` | LDAP server configuration |
| `keycloak_data` | `keycloak` | Realm config, client registrations, user data |
| `boundary_db_data` | `boundary-db` | Boundary PostgreSQL data directory |
| `boundary_controller_data` | `boundary-controller` | Controller persistent state |
| `boundary_ingress_data` | `boundary-ingress-worker` | Ingress worker persistent state |
| `boundary_egress_data` | `boundary-egress-worker` | Egress worker persistent state |

---

## Recommended Lab Path

The current repository supports more than one path through the connectors. The recommended lab order for students is:

1. `wired`
2. `env`
3. `vault`
4. `approle`
5. `approle-dynamic`
6. `approle-rotation`
7. `agent-dynamic`
8. `jwt-rotation`
9. `jwt-roles`
10. `jwt-ciba`

This is the path described in the workshop connector documentation and is the right teaching progression for the labs.

### Validation note

The `switch_connector.sh` script currently supports one additional connector mode:

- `dynamic`

That mode is available and valid, but the recommended lab path above intentionally skips it to keep the student journey tighter:

- `vault` demonstrates central secret storage
- `approle` demonstrates scoped machine identity
- `approle-dynamic` then demonstrates dynamic credentials on top of AppRole

So:

- **supported by script:** 11 connector modes
- **recommended lab journey:** 10 phases

---

## Supported Connector Modes

As validated from `scripts/switch_connector.sh`, the currently supported connector values are:

- `wired`
- `env`
- `vault`
- `dynamic`
- `agent-dynamic`
- `approle`
- `approle-dynamic`
- `approle-rotation`
- `jwt-rotation`
- `jwt-roles`
- `jwt-ciba`

To list them live:

```bash
./scripts/switch_connector.sh --list
```

To see the active mode:

```bash
./scripts/switch_connector.sh --current
```

---

## Getting Started

### Prerequisites

- Docker or Podman with Compose
- `curl`
- `jq`
- Vault Enterprise license file present at `vault/config/vault.hclic`

### Clone the repository

```bash
git clone https://github.com/raymonepping/zero_trust.git
cd zero_trust
```

### Prepare local configuration

Create the audit directory and your local environment file if needed:

```bash
mkdir -p vault/audit
cp .env.example .env
```

Do not commit `.env`, `vault/init.txt`, or any locally generated secrets.

---

## Phase 0: Start The Lab Without Vault

The first launch should come up in the baseline `wired` configuration.

### 1. Start the foundational services

Start the core services required before backend and frontend:

```bash
docker compose up -d db openldap keycloak
```

If you want the optional LDAP admin UI as well:

```bash
docker compose up -d ldap-admin
```

or:

```bash
docker compose --profile tools up -d
```

### 2. Load the workshop data

Seed PostgreSQL:

```bash
./scripts/seed_db.sh
```

Bootstrap LDAP:

```bash
./scripts/setup_ldap.sh
```

Configure Keycloak:

```bash
./scripts/setup_keycloak.sh
```

### 3. Reset connector to `wired`

Do this explicitly so the lab starts from the right baseline:

```bash
./scripts/switch_connector.sh --replace-with wired
```

### 4. Start backend and frontend

```bash
docker compose up -d backend frontend
```

At this point the UI should come up using the `wired` connector and the first lab can begin.

---

## Progressing Through The Labs

The recommended progression is below. Each step builds on the previous one.

### 1. `wired`

```bash
./scripts/switch_connector.sh --replace-with wired
```

Hardcoded credentials in source code. This is the intentionally bad starting point.

### 2. `env`

```bash
./scripts/switch_connector.sh --replace-with env
```

Credentials moved out of source and into environment variables.

### 3. `vault`

Before switching:

```bash
docker compose up -d vault
./scripts/unseal_vault.sh
./scripts/setup_vault.sh
```

Then:

```bash
./scripts/switch_connector.sh --replace-with vault
```

Static database credentials are now stored in Vault KV instead of code or `.env`.

### 4. `approle`

```bash
./scripts/switch_connector.sh --replace-with approle
```

The backend stops using broad Vault access and authenticates through AppRole instead.

### 5. `approle-dynamic`

```bash
./scripts/switch_connector.sh --replace-with approle-dynamic
```

Static DB secrets are replaced with dynamic database users issued by Vault.

### 6. `approle-rotation`

```bash
./scripts/switch_connector.sh --replace-with approle-rotation
```

Dynamic DB credentials are proactively renewed before expiry.

### 7. `agent-dynamic`

Start Vault Agent:

```bash
docker compose up -d vault-agent
```

Then switch:

```bash
./scripts/switch_connector.sh --replace-with agent-dynamic
```

The backend now reads rendered credentials from the shared Vault Agent secrets volume instead of calling Vault directly.

### 8. `jwt-rotation`

```bash
./scripts/switch_connector.sh --replace-with jwt-rotation
```

The backend authenticates to Vault using the end user’s Keycloak JWT.

### 9. `jwt-roles`

```bash
./scripts/switch_connector.sh --replace-with jwt-roles
```

Vault DB roles and Postgres access are now tied to the JWT role claim.

### 10. `jwt-ciba`

Before switching, complete the CIBA setup:

```bash
./scripts/setup_ciba.sh
./scripts/setup_ciba_keycloak.sh
```

Then:

```bash
./scripts/switch_connector.sh --replace-with jwt-ciba
```

Reads remain role-scoped, while writes require explicit approval through CIBA.

---

## Key URLs

| Component | URL | Notes |
| --- | --- | --- |
| Frontend | `http://localhost:8088` | Main student UI |
| Backend | `http://localhost:3000` | API |
| Vault | `http://localhost:8200` | Vault UI / API |
| LDAP Admin | `http://localhost:8081` | OpenLDAP admin UI |
| Keycloak | `http://localhost:8082` | Identity provider admin UI |
| Ollama | `http://localhost:11434` | Local LLM endpoint |
| OpenAPI JSON | `http://localhost:3000/openapi.json` | Exposed when `EXPOSE_ROUTES=true` |
| Swagger UI | `http://localhost:3000/docs` | Exposed when `EXPOSE_ROUTES=true` |
| PostgreSQL | `localhost:5432` | DB port |
| OpenLDAP | `localhost:1389` | LDAP |
| Boundary Controller | `http://localhost:9200` | Boundary API and UI (`access-control` profile) |
| Boundary Ingress Worker | `localhost:9202` | SSH proxy entry point (`access-control` profile) |

Note: frontend host port comes from `VITE_HOST_PORT` and defaults to `8088` in the current Compose file.

---

## Useful Commands

Start the full stack:

```bash
docker compose up -d
```

Start only the early-lab services:

```bash
docker compose up -d db openldap keycloak backend frontend
```

Show current connector:

```bash
./scripts/switch_connector.sh --current
```

Inspect running containers:

```bash
./scripts/inspect_containers.sh
```

Tail the Vault audit log:

```bash
./scripts/audit_log.sh
```

Rotate the Vault audit log:

```bash
./scripts/rotate_vault_audit.sh
```

Build and publish workshop images:

```bash
./scripts/setup_images.sh 1.8.20
```

Clean up old local workshop image tags:

```bash
./scripts/purge_images.sh
./scripts/purge_images.sh --apply
```

---

## Repository Docs

The root README is the lab entry point. The detailed subsystem docs live under `./docs`.

Key docs:

- [index.md](./index.md)
- [docs/readme_environment_settings.md](./docs/readme_environment_settings.md)
- [docs/readme_openapi.md](./docs/readme_openapi.md)
- [docs/readme_frontend.md](./docs/readme_frontend.md)
- [docs/readme_backend.md](./docs/readme_backend.md)
- [docs/readme_routes.md](./docs/readme_routes.md)
- [docs/readme_switch_connector.md](./docs/readme_switch_connector.md)
- [docs/readme_docker.md](./docs/readme_docker.md)
- [docs/readme_podman.md](./docs/readme_podman.md)
- [docs/readme_setup_vault.md](./docs/readme_setup_vault.md)
- [docs/readme_vault_unseal.md](./docs/readme_vault_unseal.md)
- [docs/readme_setup_ldap.md](./docs/readme_setup_ldap.md)
- [docs/readme_setup_keycloak.md](./docs/readme_setup_keycloak.md)
- [docs/readme_setup_ciba_vault.md](./docs/readme_setup_ciba_vault.md)
- [docs/readme_setup_ciba_keycloak.md](./docs/readme_setup_ciba_keycloak.md)
- [docs/readme_seed_db.md](./docs/readme_seed_db.md)
- [docs/readme_inspect_containers.md](./docs/readme_inspect_containers.md)
- [docs/readme_images_build.md](./docs/readme_images_build.md)
- [docs/readme_images_purge.md](./docs/readme_images_purge.md)

---

## Operational Notes

- `frontend` and `backend` are bind-mounted in Compose so local code changes are reflected in the running containers
- `backend/connector.js` is intentionally swappable as the main workshop mechanic
- `vault-agent` is optional and only needed for the agent-based phase
- `jwt-ciba` is the most advanced mode and requires both Vault and Keycloak CIBA setup
- the frontend includes a delegated write UI for the CIBA phase
- the backend exposes CIBA routes only when the active connector supports them
- `ollama` is only on the egress-enabled network for model pulls

### Security hygiene

- never commit `.env`
- never commit `vault/init.txt`
- never commit real Vault tokens, client secrets, or generated credentials in docs
- treat any accidentally exposed root token as compromised and rotate or revoke it

---

## Final note

If you want the most accurate connector-specific details, use this root README for orientation and then read [docs/readme_switch_connector.md](./docs/readme_switch_connector.md) for the full per-phase explanation.
