# backend/ — Express Backend Overview

**Location:** `backend/`

This document explains the Express-based backend used in the Zero Trust Workshop. It is written for students who need to understand how the labs work, and for engineers who may want to extend, debug, or review the implementation.

The backend is the workshop’s control plane. It sits between the frontend and the data services and is responsible for:

- database access
- connector-driven credential retrieval
- Vault and role-aware access patterns
- Keycloak JWT handling
- CIBA delegated write approval
- natural language query orchestration via Ollama
- operational health and lease introspection

The backend is intentionally modular so the workshop can swap security models without rewriting the whole application.

---

## Table Of Contents

- [Purpose](#purpose)
- [High-Level Responsibilities](#high-level-responsibilities)
- [Backend Module Layout](#backend-module-layout)
- [Runtime Model](#runtime-model)
- [How Requests Flow Through The Backend](#how-requests-flow-through-the-backend)
- [Authentication Model](#authentication-model)
- [Authorization Model](#authorization-model)
- [Connector And Pool Model](#connector-and-pool-model)
- [API Surface](#api-surface)
- [Natural Language Query Flow](#natural-language-query-flow)
- [CIBA Delegated Write Flow](#ciba-delegated-write-flow)
- [Environment And Configuration](#environment-and-configuration)
- [Logging](#logging)
- [Container And Development Behavior](#container-and-development-behavior)
- [Useful Operational Notes](#useful-operational-notes)
- [Troubleshooting](#troubleshooting)

---

## Purpose

The frontend does not talk directly to PostgreSQL, Vault, Keycloak, or OpenLDAP. All meaningful access goes through this backend.

That is deliberate. The backend is where the workshop expresses the security model for each phase:

- early phases use static or environment-driven credentials
- mid phases use Vault and AppRole
- later phases use dynamic credentials, role scoping, and JWT-based identity
- the final phase adds CIBA approval for writes

The backend therefore acts as both:

- the application API
- the security boundary for the labs

---

## High-Level Responsibilities

The backend performs six major jobs.

### 1. Serve application APIs

It exposes routes for:

- users
- orders
- preferences
- training
- tickets
- projects

### 2. Resolve credentials through the active connector

The workshop’s active connector determines how the backend obtains database credentials:

- hardcoded
- environment-based
- Vault KV
- AppRole
- Vault Agent
- JWT-scoped
- CIBA-enabled write credentials

### 3. Manage database pools

The backend does not open a new database connection per request. It maintains role-aware Postgres pools and rotates them safely when credentials change or expire.

### 4. Authenticate end users

It validates incoming Bearer tokens and converts JWT claims into backend user context.

### 5. Enforce data visibility rules

Two independent security layers apply:

- trust level controls which classifications are visible
- role mapping controls which database role and grants the user receives

### 6. Proxy and orchestrate external identity and AI services

The backend:

- proxies login to Keycloak
- handles CIBA approval orchestration
- forwards natural language prompts to Ollama after building filtered context

---

## Backend Module Layout

The backend directory currently contains:

- [server.js](../backend/server.js)  
  Main Express application entry point and route registration.

- [auth.js](../backend/auth.js)  
  JWT verification middleware for required and optional authentication.

- [pool-manager.js](../backend/pool-manager.js)  
  Database pool lifecycle, role-aware pool selection, rotation, and recovery.

- [connector.js](../backend/connector.js)  
  The active credential provider. This file is intentionally swappable.

- [roleResolver.js](../backend/roleResolver.js)  
  Maps JWT realm roles and groups to backend Vault/Postgres role names.

- [ciba.js](../backend/ciba.js)  
  In-memory manager for the CIBA lifecycle.

- [ciba-routes.js](../backend/ciba-routes.js)  
  Express routes for delegated approval and CIBA-gated writes.

- [logger.js](../backend/logger.js)  
  Winston logger setup and Morgan integration.

- [package.json](../backend/package.json)  
  Runtime dependencies and scripts.

- [Dockerfile](../backend/Dockerfile)  
  Container image definition for the backend.

---

## Runtime Model

The backend runs as:

- Node.js
- Express 5
- inside a Docker container

### Package scripts

From [package.json](../backend/package.json):

```json
{
  "scripts": {
    "start": "node server.js",
    "dev": "nodemon --watch server.js --watch connector.js --watch ciba.js --watch ciba-routes.js server.js"
  }
}
```

In the container, the backend runs:

```bash
npm run dev
```

which means:

- `nodemon` watches key backend files
- connector swaps are picked up quickly
- the workshop can change security modes live without rebuilding the image

### Docker behavior

From [Dockerfile](../backend/Dockerfile):

- base image: `node:25.8.2-alpine3.23`
- working directory: `/app`
- installs dependencies with `npm ci`
- exposes port `3000`
- starts with `npm run dev`

In Compose, `./backend` is bind-mounted into the container, so local file edits affect the running backend.

---

## How Requests Flow Through The Backend

Typical request path:

```text
Browser
  -> frontend
  -> backend route
  -> optional JWT authentication
  -> role resolution
  -> pool-manager query using active connector-derived credentials
  -> filtered result returned to frontend
```

For natural language queries:

```text
Browser
  -> frontend
  -> POST /ask
  -> backend fetches filtered SQL datasets
  -> backend constructs a constrained prompt
  -> Ollama generates streamed response
  -> backend streams text back to frontend
```

For CIBA-gated writes:

```text
Browser
  -> frontend CIBA request
  -> backend initiates Keycloak CIBA
  -> user approves
  -> backend polls token endpoint
  -> backend fetches short-lived write credential
  -> backend performs UPDATE
  -> backend revokes the write lease
```

---

## Authentication Model

User authentication is handled in [auth.js](../backend/auth.js).

This module verifies Bearer tokens and attaches:

```js
req.user
req.userContext = {
  sub,
  role,
  email
}
```

### Supported token verification styles

The verifier is initialized lazily and supports two modes:

#### 1. JWKS / RS256

Used for a production-style pattern, such as Keycloak:

- set `JWKS_URL`
- optionally set `JWT_ISSUER`

#### 2. Shared secret / HS256

Used for development or testing:

- set `JWT_SECRET`

### Middleware styles

Two middleware variants exist:

#### `authenticate`

Used for routes that require a valid JWT.

If the header is missing or invalid:

- response is `401`

#### `authenticateOptional`

Used for routes where anonymous access is still allowed.

If no valid JWT is present:

- request continues
- `req.userContext` is left undefined
- the backend falls back to a least-privilege view

This is why the frontend can still work for anonymous read paths in earlier phases.

---

## Authorization Model

The backend enforces access using two independent layers.

### 1. Trust level

In [server.js](../backend/server.js), trust level is derived from the active connector `source`.

Current trust mapping:

- `static-config` -> level 0
- `env-file` -> level 0
- `vault-kv` -> level 1
- `vault-dynamic` -> level 1
- `vault-approle` -> level 2
- `vault-approle-dynamic` -> level 2
- `vault-jwt-dynamic` -> level 3

That trust level maps to visible classification sets:

- `public`
- `internal`
- `confidential`
- `restricted`

The backend uses this for SQL filtering, especially in routes like:

- `/preferences`
- `/training`
- `/tickets`
- `/projects`
- `/ask`

### 2. Role scoping

[roleResolver.js](../backend/roleResolver.js) maps JWT claims and groups to canonical Vault/Postgres role names:

- `viewer-read`
- `support-read`
- `admin-read`

This lets the pool manager choose the right pool and lets the connector request the correct role-specific credential where supported.

### Why both layers matter

These two layers are intentionally separate:

- trust level answers: “which classifications are even queryable in this workshop phase?”
- role scoping answers: “which role-specific credential should this user receive?”

That provides defense in depth.

---

## Connector And Pool Model

The active connector is imported from:

- [connector.js](../backend/connector.js)

This file is swapped by `switch_connector.sh`.

### Connector compatibility shims

The backend has to work across older and newer connector generations. Because of that, [server.js](../backend/server.js) and [pool-manager.js](../backend/pool-manager.js) include compatibility fallbacks when connectors do not implement newer helpers.

This is important for the workshop because:

- not all connector phases expose the same methods
- the backend still needs stable behavior across all phases

### Pool manager responsibilities

[pool-manager.js](../backend/pool-manager.js) is one of the most important modules in the backend.

It is responsible for:

- creating Postgres pools from resolved credentials
- tracking pools by Vault/Postgres role
- rotating pools when credentials change
- handling proactive connector-driven rotations
- recovering from authentication failures reactively
- exposing runtime status for diagnostics

### Role-aware pool map

Internally, pools are stored per role:

```text
Map<vaultRole, state>
```

This allows the backend to maintain separate pool state for:

- `viewer-read`
- `support-read`
- `admin-read`

where the active connector supports role-specific credentials.

### Lazy pool creation

Pools are not necessarily created for every role at startup.

If a role is requested and its pool does not yet exist:

- the backend fetches credentials for that role
- builds the pool on demand
- stores it for future use

This keeps startup lighter while still supporting role-specific access.

### Rotation model

There are two types of rotation:

#### Proactive rotation

The connector emits updated credentials when it renews or rotates them.

The pool manager then:

- builds a new validated pool
- swaps it in atomically
- drains the old pool
- optionally revokes the previous lease

#### Reactive recovery

If Postgres returns credential/authentication failure codes such as:

- `28P01`
- `28000`
- `08006`

the pool manager requests a fresh credential and retries the query once.

This allows the workshop to recover cleanly when a lease expires or becomes invalid.

### Status surface

The pool manager exposes a status object used by:

- `/credentials`
- `/health/lease`

This includes:

- per-pool counts
- rotation count
- lease details
- whether rotation is active

---

## API Surface

The backend’s main routes are registered in [server.js](../backend/server.js).

### Health and diagnostics

- `GET /`
  - simple DB connectivity probe

- `GET /health`
  - DB health
  - Vault health when relevant
  - returns degraded if DB or required Vault use is unhealthy

- `GET /credentials`
  - active credential metadata
  - connector phase
  - capability flags such as `ciba_write`
  - trust level
  - classification access
  - pool and lease state

- `GET /health/lease`
  - lease and pool rotation status per role

- `POST /health/lease/rotate`
  - forces manual credential rotation

- `GET /openapi.json`
  - returns the OpenAPI definition when route exposure is enabled

- `GET /docs`
  - serves Swagger UI backed by the OpenAPI definition when route exposure is enabled

### Data APIs

All of these use `authenticateOptional`, so the backend can fall back to least privilege if no user JWT is present:

- `GET /users`
- `GET /orders`
- `GET /preferences`
- `GET /training`
- `GET /tickets`
- `GET /projects`

Important behavior:

- the backend often catches Postgres permission errors (`42501`) and returns an empty set instead of crashing
- this is part of the workshop design because some phases intentionally use narrower GRANT scopes

### AI query API

- `POST /ask`

This route:

- reads a natural language question
- chooses which datasets are relevant
- queries only allowed data
- builds a constrained prompt
- streams Ollama output back to the frontend

### Auth proxy

- `POST /auth/token`

This route exchanges username/password against Keycloak and returns only:

- `access_token`
- `expires_in`

It exists because the frontend cannot reach Keycloak directly on the internal Docker network.

### CIBA routes

Mounted under:

- `/ciba`

These are implemented in [ciba-routes.js](../backend/ciba-routes.js).

They are described in detail below.

---

## Natural Language Query Flow

The `/ask` route is more than a simple proxy.

### Dataset selection

The backend first chooses which datasets to query based on keywords in the user’s question.

Examples:

- “orders” or “spent” -> orders
- “preferences” or “interests” -> preferences
- “training” or “course” -> training
- “tickets” or “priority” -> tickets
- “projects” or “budget” -> projects

If the question is broad, the backend falls back to all datasets.

### Data filtering

The backend then:

- resolves active trust level
- computes allowed classifications
- applies those filters in SQL
- respects role-based database grants

### Prompt construction

The prompt sent to Ollama is highly constrained:

- use only provided data
- do not infer missing facts
- compare exact numeric values only
- explicitly say when data is insufficient

This is an important teaching choice. It shows how to reduce hallucination risk by controlling context and instructions before data ever reaches the model.

### Streaming response

The backend calls:

- `${OLLAMA_ADDR}/api/generate`

with streaming enabled and forwards incremental response chunks to the frontend as they arrive.

---

## CIBA Delegated Write Flow

The final workshop phase adds delegated write approval through CIBA.

This is implemented across:

- [ciba.js](../backend/ciba.js)
- [ciba-routes.js](../backend/ciba-routes.js)

### What CIBA is doing here

The workshop uses CIBA to gate high-impact writes behind explicit user approval.

Instead of granting broad write access up front:

1. the user initiates a write action
2. Keycloak creates a backchannel approval request
3. the user approves
4. the backend receives a CIBA token
5. the backend fetches a short-lived write credential
6. the backend performs the write
7. the write lease is revoked

### CIBA route groups

#### Keycloak callback endpoint

- `POST /ciba/request`

Receives the delegation request from Keycloak and stores it in memory for polling.

#### Frontend-facing CIBA routes

- `POST /ciba/initiate`
- `GET /ciba/pending`
- `POST /ciba/approve`
- `GET /ciba/status/:sessionId`

These drive the approval UI in the frontend.

#### Write-gated action

- `POST /orders/:id/status`

This route is only enabled when the active connector reports:

```js
CAPABILITIES.ciba_write === true
```

### In-memory state

Two in-memory stores are used:

#### Pending requests

Managed in `ciba.js`

- keyed by Keycloak delegation bearer token
- tracks pending / approved / denied / expired decisions

#### CIBA sessions

Managed in `ciba-routes.js`

- keyed by local session id
- tracks initiate -> poll -> execute lifecycle

This means CIBA state is intentionally not durable across restarts. That is acceptable for a workshop.

### Write execution model

After approval, the backend:

- calls `connector.getWriteCredentials(req.userContext)`
- creates a one-off `pg.Pool` using the write credential
- performs the `UPDATE orders SET status = ...`
- revokes the lease if present
- marks the CIBA session as executed

This path is intentionally isolated from the normal read pools.

That separation is valuable because it demonstrates:

- read and write credentials can be different
- write privileges can be narrower and shorter-lived
- approval can be attached to the write lifecycle itself

---

## Environment And Configuration

The backend reads many settings from environment variables. The most important groups are:

### Core runtime

- `PORT`
- `NODE_ENV`
- `LOG_LEVEL`

### Database

- `DATABASE_URL`

Used as a fallback for older/static connector modes when explicit credential fields are not provided.

### Vault

- `VAULT_ADDR`
- connector-specific Vault auth and role settings
- `VAULT_AGENT_CREDS_FILE` for the Vault Agent phase

### JWT auth

- `JWT_SECRET`
- `JWKS_URL`
- `JWT_ISSUER`

### Keycloak

- `KEYCLOAK_ADDR`
- `KEYCLOAK_REALM`
- `KEYCLOAK_CLIENT_ID`
- `KEYCLOAK_CLIENT_SECRET`

### OpenAPI and docs exposure

- `EXPOSE_ROUTES`

When set to `true`, the backend exposes:

- `http://localhost:3000/openapi.json`
- `http://localhost:3000/docs`

These routes are intentionally unauthenticated in the current workshop setup.

### Ollama

- `OLLAMA_ADDR`

### CIBA tuning

- `CIBA_POLL_INTERVAL`
- `CIBA_TIMEOUT`

The exact connector-related variables depend on which connector is currently active.

---

## Logging

Logging is handled by [logger.js](../backend/logger.js) using Winston.

### Development mode

When `NODE_ENV` is not `production`:

- colorized logs
- timestamps
- readable metadata formatting

### Production mode

- JSON logs

### Morgan integration

HTTP access logs are piped through the same logger via:

- `log.stream`

This keeps request logs and application logs in one output stream.

### CIBA log hygiene

The current backend intentionally keeps noisy token-like identifiers out of normal `info` logs and moves them to `debug` where possible. That keeps workshop output readable while preserving deep troubleshooting when needed.

---

## Container And Development Behavior

The backend container is designed for live workshop iteration.

### Why `connector.js` is swappable

The central workshop mechanic is the ability to replace:

- `backend/connector.js`

without rebuilding the image.

This works because:

- the backend directory is bind-mounted
- nodemon watches the key runtime files
- `switch_connector.sh` swaps the file and restarts the container

### OpenAPI and Swagger UI

The backend now includes:

- [openapi.json](../backend/openapi.json)
- [openapi-routes.js](../backend/openapi-routes.js)

When `EXPOSE_ROUTES=true`, these are served at:

- `http://localhost:3000/openapi.json`
- `http://localhost:3000/docs`

The implementation is intentionally separate from the main route file so `server.js` stays focused on application startup and core route registration.

### Why that matters educationally

Students can experience multiple security models using the same UI and same API surface. Only the credential strategy changes.

This is one of the best properties of the workshop design.

---

## Useful Operational Notes

### Anonymous fallback

Many read routes work without a JWT because the backend intentionally supports anonymous least-privilege behavior for early phases.

### Role fallback

If no user is present, the backend usually falls back to:

- `viewer-read`

This keeps behavior safe by default.

### Connector compatibility

The backend contains a lot of backward-compatibility logic so older workshop connectors still work. That means:

- the code may look more defensive than a single-mode production backend
- that is intentional for workshop continuity

### Vault health behavior

Vault is treated as required only when the active connector mode actually depends on it. This prevents early phases from failing just because Vault is not yet in use.

---

## Troubleshooting

### Backend starts but routes fail with pool errors

Check:

- the active connector is valid
- the connector can obtain credentials
- PostgreSQL is reachable
- the pool manager initialized successfully

### JWT-authenticated routes behave like anonymous access

Check:

- JWT verification settings (`JWKS_URL` or `JWT_SECRET`)
- issuer configuration
- whether the token contains expected realm roles or groups

### `/ask` returns too little or empty results

That can be caused by:

- trust-level filtering
- role-based SQL permissions
- missing dataset keyword matches

This is not always a bug; in many cases it reflects the intended lab restrictions.

### CIBA endpoints return 404

That usually means the active connector does not advertise:

```js
CAPABILITIES.ciba_write === true
```

In practice, this means you are not on the `jwt-ciba` connector.

### Write flow fails after CIBA approval

Check:

- Keycloak CIBA setup
- write-scoped Vault role configuration
- whether `connector.getWriteCredentials()` is implemented by the active connector
- whether the target order exists

### Vault Agent phase does not work

Check:

- `vault-agent` container is running
- the shared `vault-agent-secrets` volume is mounted
- the rendered credential file exists at the configured path

---

## Summary

The backend is the workshop’s most important moving part. It is where:

- user identity is verified
- connector-selected credential strategies are applied
- role-aware database pools are managed
- data visibility rules are enforced
- LLM queries are grounded in filtered SQL data
- CIBA approval is turned into short-lived write access

For students, it demonstrates how application architecture changes as secret handling matures. For engineers, it shows how one codebase can support multiple security models by isolating credential logic behind a connector and pool-management boundary.
