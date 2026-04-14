# Architecture

This document describes the complete architecture of the Zero Trust Workshop — how services relate to each other, which access patterns are demonstrated, and where zero-trust principles are applied.

For startup instructions and lab progression see [README.md](../README.md).

---

## Table of Contents

- [The Core Idea](#the-core-idea)
- [Two Planes, One Database](#two-planes-one-database)
- [Unified Architecture Diagram](#unified-architecture-diagram)
- [End-User Plane](#end-user-plane)
- [Operator Plane — Boundary](#operator-plane--boundary)
- [Identity and Credential Infrastructure](#identity-and-credential-infrastructure)
- [Zero-Trust Principles Applied](#zero-trust-principles-applied)
- [Network Topology](#network-topology)

---

## The Core Idea

The workshop is built around a single question:

> Who needs to reach the database, how do they get there, and how do we ensure neither path requires long-lived secrets or direct network exposure?

The answer is two distinct access planes:

| Actor | Plane | Path | Zero-Trust Mechanism |
| ----- | ----- | ---- | -------------------- |
| End user (browser) | Application | Frontend → Backend → PostgreSQL | Vault dynamic credentials, Keycloak JWT |
| Operator (DBA / SRE) | Infrastructure | Boundary Client → Boundary → PostgreSQL / Ubuntu | Vault-brokered credentials, multi-hop session, no direct network access |

Neither actor holds a persistent credential. Neither has a direct route to the database.

---

## Two Planes, One Database

PostgreSQL is **dual-homed**: it sits on `net-data` (the application network) and `net-boundary-private` (the Boundary private network). This is deliberate — it means the same data store is reachable via two completely separate trust paths.

```text
  Application traffic                     Operator traffic
  ─────────────────────────               ────────────────────────────────────
  non-human · programmatic                human · interactive
  short-lived Vault credentials           Vault-brokered operator credentials
  role-scoped via JWT                     no direct network access

         Backend (Express)                        Egress Worker
               │                                        │
               │  net-data                              │  net-boundary-private
               └────────────────────┐  ┌────────────────┘
                                    ▼  ▼
                             ╔════════════════╗
                             ║  PostgreSQL    ║
                             ║    :5432       ║
                             ╚════════════════╝
                                                   ▲
                                                   │
                                            ╔══════════════╗
                                            ║ Ubuntu SSH   ║
                                            ║     :22      ║
                                            ╚══════════════╝
```

---

## Unified Architecture Diagram

The diagram below shows both planes together with all supporting services.

```text
  ┌──────────────── END-USER PLANE ──────────────────┐
  │                                                  │
  │  Browser                                         │
  │    │  HTTP  :8088                                │
  │    ▼                                             │
  │  Frontend  (React / Vite)     net-frontend       │
  │    │  /api/*  :3000                              │
  │    ▼                                             │
  │  Backend  (Express)           net-backend        │
  │    │                          net-data           │
  │    ├──► Vault       :8200     dynamic creds      │
  │    ├──► Keycloak    :8082     JWT / CIBA auth    │
  │    ├──► OpenLDAP    :1389     identity source    │
  │    └──► Ollama      :11434    /api/ask (LLM)     │
  │                                                  │
  └──────────────────────────┬───────────────────────┘
                             │  net-data
                             │  short-lived dynamic credentials
                             │
  ┌──────────────── OPERATOR PLANE ──────────────────┐
  │                                                  │
  │  Boundary Client / Desktop App                   │
  │    │  :9200  authenticate                        │
  │    │  :9202  proxy session                       │
  │    ▼                                             │
  │  ┌───────────────────────────────────────────┐   │
  │  │  net-boundary-control                     │   │
  │  │  boundary-db  ◄──  boundary-controller    │   │
  │  │                    ingress-worker  :9202  │   │
  │  └──────────────────────────┬────────────────┘   │
  │                             │  hop 1             │
  │  ┌──────────────────────────▼───────────────┐    │
  │  │  net-boundary-dmz                        │    │
  │  │              egress-worker               │    │
  │  └──────────────────────────┬───────────────┘    │
  │                             │  hop 2             │
  │  ┌──────────────────────────▼───────────────┐    │
  │  │  net-boundary-private                    │    │
  │  │  boundary-ssh :22   db :5432   nginx :80 │    │
  │  └──────────────────────────┬───────────────┘    │
  │                             │  Vault-brokered DB creds / SSH certs
  └─────────────────────────────┼────────────────────┘
                                │  brokered session · no direct network path
                                │
                                ▼
     ╔════════════════╗             ╔════════════════╗
     ║  PostgreSQL    ║             ║  Ubuntu SSH    ║
     ║    :5432       ║             ║      :22       ║
     ╚════════════════╝             ╚════════════════╝
```

---

## End-User Plane

The end-user plane is the **application access path**. A browser interacts with the React frontend, which delegates all data and auth operations to the Express backend.

```text
  Browser
    │  HTTP  :8088
    ▼
╔══════════════════════════════════════════════════════════════════════════════╗
║  net-frontend                                                                ║
║  ┌────────────────────────────────────────────────────────────────────────┐  ║
║  │  Frontend  (React / Vite)                              port 8088       │  ║
║  └────────────────────────────────────┬───────────────────────────────────┘  ║
╚══════════════════════════════════════╦╧══════════════════════════════════════╝
                                       │  /api/*  :3000
╔══════════════════════════════════════╩═══════════════════════════════════════╗
║  net-backend                                                                 ║
║  ┌────────────────────────────────────────────────────────────────────────┐  ║
║  │  Backend  (Express)                                    port 3000       │  ║
║  └────┬──────────┬──────────┬──────────┬──────────────────────────────────┘  ║
╚═══════╪══════════╪══════════╪══════════╪═════════════════════════════════════╝
        │          │          │          │
╔═══════╪══════════╪══════════╪══════════╪═════════════════════════════════════╗
║  net-data        │          │          │                                     ║
║  ┌────▼──────┐ ┌─▼──────┐ ┌─▼───────┐  └──► vault-agent-secrets (volume)     ║
║  │ PostgreSQL│ │ Vault  │ │Keycloak │      ▲  rendered by Vault Agent        ║
║  │  :5432    │ │ :8200  │ │  :8082  │      │                                 ║
║  └───────────┘ └────────┘ └────┬────┘  ┌───┴───────────┐                     ║
║                                │       │  Vault Agent  │──► Vault :8200      ║
║                                ▼       └───────────────┘                     ║
║                           ┌──────────┐  ┌─────────────┐  ┌──────────────┐    ║
║                           │ OpenLDAP │  │  LDAP Admin │  │   Ollama     │    ║
║                           │  :1389   │  │  :8081      │  │   :11434     │    ║
║                           └──────────┘  └─────────────┘  └──────┬───────┘    ║
╚═════════════════════════════════════════════════════════════════╪════════════╝
                                                                  │ model pulls
╔═════════════════════════════════════════════════════════════════╪════════════╗
║  net-egress                                                     │            ║
║                                                          ┌──────▼────────┐   ║
║                                                          │   Internet    │   ║
║                                                          └───────────────┘   ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

### How credentials flow in the application plane

The workshop progresses through multiple credential strategies, all managed by swapping `backend/connector.js`:

1. **`wired`** — hardcoded in source (intentionally broken baseline)
2. **`env`** — moved to `.env` file
3. **`vault`** — stored in Vault KV; backend calls Vault directly with a root-style token
4. **`approle`** — backend authenticates to Vault via AppRole; scoped machine identity
5. **`approle-dynamic`** — Vault issues short-lived PostgreSQL users on demand
6. **`agent-dynamic`** — Vault Agent renders credentials to a shared volume; backend reads a file, never calls Vault
7. **`jwt-rotation`** — backend authenticates to Vault using the end user's Keycloak JWT
8. **`jwt-roles`** — Vault DB roles are bound to the JWT role claim; access is role-scoped
9. **`jwt-ciba`** — reads remain role-scoped; writes require explicit user approval via CIBA

---

## Operator Plane — Boundary

The operator plane is the **human access path**. An operator connects through Boundary — they receive a brokered session and never hold a raw database credential, a long-lived SSH trust artifact, or a direct route to the target.

```text
  Boundary Client / Desktop App
      │
      │  :9200  authenticate and authorize
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

### Why multi-hop matters

The three-zone layout reflects a real-world DMZ pattern:

| Zone          | Network                 | Role                                                           |
| ------------- | ----------------------- | -------------------------------------------------------------- |
| Control plane | `net-boundary-control`  | Controller manages sessions and authorisation; internal only   |
| DMZ           | `net-boundary-dmz`      | Ingress and egress workers can see each other but nothing else |
| Private       | `net-boundary-private`  | PostgreSQL, Ubuntu SSH, and demo targets live here; only the egress worker can reach them |

The Boundary client connects to the ingress worker at `:9202`. The ingress worker tunnels the session to the egress worker (hop 1). The egress worker makes the final connection to the target (hop 2). **At no point does the client have a routable path to the target network.**

For the workshop's operator path, Boundary brokers two credential types through Vault:

- **PostgreSQL access** uses Vault-issued dynamic database credentials from `database/creds/*`
- **Ubuntu access** uses Vault's SSH client signer at `ssh-client-signer/sign/boundary-role`

---

## Identity and Credential Infrastructure

Both planes rely on a shared identity and credential layer:

| Service | Role | Used by |
| --- | --- | --- |
| **Vault** | Credential authority — issues dynamic DB credentials, signs SSH client credentials, validates JWT auth, manages AppRole identities | Backend (all dynamic connector modes), Vault Agent, Boundary operator path |
| **Keycloak** | OIDC provider — issues JWTs, maps LDAP roles to JWT claims, handles CIBA backchannel auth | Backend (jwt-* connector modes), frontend (CIBA approval UI) |
| **OpenLDAP** | Identity source — users, groups, role assignments | Keycloak (user federation), LDAP Admin (management) |
| **Vault Agent** | Sidecar credential renderer — authenticates to Vault and writes `db-creds.json` to a shared volume | Backend in `agent-dynamic` mode |

### Credential lifecycle in the operator plane

```text
  Boundary Client
      │
      │ authenticate to Boundary
      ▼
  Boundary Controller
      │
      ├──► Vault  ──► database/creds/<role>             ──► short-lived PostgreSQL username/password
      │
      └──► Vault  ──► ssh-client-signer/sign/boundary-role ──► short-lived signed SSH client certificate
                                                             
  Ingress Worker ──► Egress Worker ──► PostgreSQL :5432 / Ubuntu SSH :22
```

The important distinction is that Boundary brokers the session and asks Vault for the credential material at session time. The operator does not need a long-lived database password or a static SSH private key that is trusted by the target.

### Credential lifecycle in the application plane

```text
  OpenLDAP  ──► (user federation) ──►  Keycloak  ──► (JWT with role claim) ──► Backend
                                                                                    │
                                                                                    │ JWT
                                                                                    ▼
                                                                                  Vault
                                                                                    │ dynamic DB creds
                                                                                    │ scoped to JWT role
                                                                                    ▼
                                                                               PostgreSQL
```

---

## Zero-Trust Principles Applied

| Principle | Where | Mechanism |
| --------- | ----- | --------- |
| No long-lived application credentials | Backend → PostgreSQL | Vault dynamic database credentials with short TTLs |
| Machine identity, not shared secrets | Backend → Vault | AppRole: role-id + secret-id instead of a root token |
| Identity-aware access | Backend → Vault → PostgreSQL | JWT role claim maps to Vault DB role maps to Postgres role |
| Explicit approval for high-impact writes | Frontend → Backend → Keycloak | CIBA backchannel: write operations require user approval on a second device |
| No direct network access for humans | Operator → PostgreSQL / Ubuntu | Boundary multi-hop: two worker hops, client never touches the private network |
| No long-lived operator credentials | Operator → PostgreSQL / Ubuntu | Vault issues dynamic DB credentials and signs short-lived SSH client credentials for Boundary-brokered sessions |
| Short-lived sessions | Operator access | Boundary issues session tokens and brokers ephemeral credentials, not persistent secrets |
| Audit trail | Both planes | Vault audit log (every credential request), Boundary session recording |
| Network segmentation | All services | Seven isolated Docker networks; no cross-network routing without an explicit bridge |

---

## Network Topology

| Network | Services | Purpose |
| ------- | -------- | ------- |
| `net-frontend` | `frontend` | Isolates UI from everything except the browser |
| `net-backend` | `frontend`, `backend` | The only path from frontend to the API |
| `net-data` | `backend`, `db`, `vault`, `vault-agent`, `ollama`, `openldap`, `ldap-admin`, `keycloak`, `boundary-egress-worker` | All internal service communication |
| `net-egress` | `ollama` | Allows model pulls from the internet; all other services are fully isolated |
| `net-boundary-control` | `boundary-db`, `boundary-controller`, `boundary-ingress-worker` | Boundary control plane; internal only |
| `net-boundary-dmz` | `boundary-ingress-worker`, `boundary-egress-worker` | Transit zone between the two worker hops |
| `net-boundary-private` | `boundary-egress-worker`, `boundary-target`, `boundary-ssh`, `db` | Protected network; only the egress worker can reach targets |

`db` is the only service that bridges the application plane (`net-data`) and the operator plane (`net-boundary-private`). This dual-homing is intentional — it is the architectural point where both zero-trust access patterns converge.
