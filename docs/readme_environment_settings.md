# .env — Environment Settings Reference

**File location:** `.env`

This document explains the root environment file used by the Zero Trust Workshop. It is written for students who need to understand what the stack expects, and for engineers who may need to review, adjust, or troubleshoot the environment configuration.

The root `.env` file is operationally important. It influences:

- backend runtime behavior
- frontend proxy settings exposed through Compose
- PostgreSQL connection fallback settings
- Vault access
- AppRole access
- JWT validation
- Keycloak integration
- local workshop defaults

This document does **not** include any secret values from the real `.env`.

---

## Table Of Contents

- [Purpose](#purpose)
- [How The Root .env Is Used](#how-the-root-env-is-used)
- [Current Variable Groups](#current-variable-groups)
- [Backend General Settings](#backend-general-settings)
- [Frontend And Vite Settings](#frontend-and-vite-settings)
- [PostgreSQL Settings](#postgresql-settings)
- [Ollama Settings](#ollama-settings)
- [Vault Settings](#vault-settings)
- [Vault AppRole Settings](#vault-approle-settings)
- [JWT And Keycloak Settings](#jwt-and-keycloak-settings)
- [Variables Supported By The Code But Not Required In The Current .env](#variables-supported-by-the-code-but-not-required-in-the-current-env)
- [Precedence And Fallback Behavior](#precedence-and-fallback-behavior)
- [Security Notes](#security-notes)
- [Troubleshooting](#troubleshooting)

---

## Purpose

The root `.env` file is the workshop’s central runtime configuration file.

It exists so the stack can:

- start consistently in Compose
- keep sensitive values out of source files
- let scripts and containers share the same configuration
- switch connector behavior without rewriting application code

In early workshop phases this file provides direct database or Vault inputs. In later phases it also feeds Keycloak and JWT-related flows.

---

## How The Root .env Is Used

The root `.env` is consumed in more than one way.

### 1. Loaded into the backend container

In [docker-compose.yml](../docker-compose.yml), the backend service uses:

```yaml
env_file:
  - .env
```

That means the backend container receives the root `.env` values as environment variables.

### 2. Used by Compose variable interpolation

Compose also uses `.env` values directly for substitutions such as:

- `VITE_PORT`
- `VITE_HOST_PORT`
- `VAULT_ADDR` fallback for `vault-agent`

### 3. Used by host-side scripts

Several scripts rely on these variables when run from the host shell, especially around:

- Vault setup and login
- audit operations
- route and CIBA tests
- connector behavior

### 4. Used indirectly by the frontend

The frontend does not load the root `.env` directly at runtime in the browser. Instead:

- Compose passes selected values into the frontend container
- Vite uses those values for dev server and proxy configuration

---

## Current Variable Groups

The current `.env` is organized into these sections:

- backend general configuration
- PostgreSQL
- Ollama
- Vault
- Vault AppRole
- Keycloak and JWT

That structure is already good. It matches the workshop progression and makes it easier to reason about which variables matter in each connector phase.

---

## Backend General Settings

These variables control core backend runtime behavior.

### `NODE_ENV`

Purpose:

- tells the backend which runtime context it is in

Current role in code:

- used by [backend/logger.js](../backend/logger.js) to determine development-oriented logging behavior

Typical values:

- `development`
- `production`
- `test`

### `LOG_LEVEL`

Purpose:

- controls backend log verbosity

Current role in code:

- used by [backend/logger.js](../backend/logger.js)

Common values:

- `debug`
- `info`
- `warn`
- `error`

### `PORT`

Purpose:

- defines the internal port the backend listens on

Current role in code:

- used by [backend/server.js](../backend/server.js)

Default fallback in code:

- `3000`

---

## Frontend And Vite Settings

These variables shape how the frontend container and Vite dev server behave.

### `VITE_API_URL`

Purpose:

- tells Vite’s proxy where the backend API lives

Current role in code:

- used by [frontend/vite.config.js](../frontend/vite.config.js)
- also surfaced in Compose for the `frontend` service

In the workshop this usually points to the backend service name on the Docker network, not `localhost`.

### `VITE_PORT`

Purpose:

- defines the internal Vite dev server port

Current role in code:

- used by [frontend/vite.config.js](../frontend/vite.config.js)
- used by `frontend/package.json`
- used by Compose port mapping and health checks

Default fallback:

- `5173`

### `VITE_HOST_PORT`

Purpose:

- defines the host port exposed for the frontend

Current role:

- used by Compose host port publishing
- shown by the frontend dev script as the browser URL

Typical result:

- browser access on `http://localhost:8088`

---

## PostgreSQL Settings

The `.env` contains both a full connection string and individual connection fields.

That is intentional because different code paths use different fallbacks.

### `DATABASE_URL`

Purpose:

- full PostgreSQL connection string

Current role in code:

- used by [backend/pool-manager.js](../backend/pool-manager.js) as a fallback
- used by [data/connector.env.js](../data/connector.env.js) when individual variables are absent

This is a generic compatibility path. It is useful because many tools and libraries already understand `DATABASE_URL`.

### `POSTGRES_DB_HOST`
### `POSTGRES_DB_PORT`
### `POSTGRES_DB`
### `POSTGRES_USER`
### `POSTGRES_PASSWORD`

Purpose:

- individual PostgreSQL connection components

Current role in code:

- used by [data/connector.env.js](../data/connector.env.js)

These are most directly relevant in the `env` connector phase.

Important note:

- the Compose file also hardcodes database bootstrap settings for the `db` service
- those service-level bootstrap variables are separate from the connector runtime variables

---

## Ollama Settings

### `OLLAMA_ADDR`

Purpose:

- tells the backend where the Ollama API is reachable

Current role in code:

- used by [backend/server.js](../backend/server.js) for `/ask`

Default fallback in code:

- `http://ollama:11434`

This is operationally important for the natural-language query flow. If this setting is wrong, `/ask` will fail even if the rest of the stack is healthy.

---

## Vault Settings

These variables control direct Vault access and Vault-backed connector behavior.

### `VAULT_ADDR`

Purpose:

- Vault HTTP API endpoint

Current role in code:

- used by multiple connectors
- used by [backend/server.js](../backend/server.js) for Vault health probes
- used by Vault-related scripts
- used by `vault-agent` Compose environment fallback

### `VAULT_TOKEN`

Purpose:

- token used for direct Vault API access

Current role in code:

- used by `vault`, `dynamic`, and `agent-dynamic` style direct Vault connectors
- used by setup and admin scripts

This is one of the most sensitive variables in the file.

### `VAULT_MODE`

Purpose:

- determines whether certain connectors read:
  - KV static secrets
  - dynamic credentials

Current role in code:

- used by [backend/connector.js](../backend/connector.js)
- used by [data/connector.dynamic.js](../data/connector.dynamic.js)
- used by [data/connector.agent-dynamic.js](../data/connector.agent-dynamic.js)

Typical modes:

- `kv`
- `dynamic`

### `VAULT_DB_ROLE`

Purpose:

- default Vault database role used for credential issuance

Current role in code:

- used by dynamic/AppRole/JWT connector variants

### `VAULT_DB_ROLE_VIEWER`
### `VAULT_DB_ROLE_SUPPORT`
### `VAULT_DB_ROLE_ADMIN`

Purpose:

- map application/user roles to specific Vault database roles

Current role in code:

- used by [data/connector.jwt-roles.js](../data/connector.jwt-roles.js)
- used by [data/connector.jwt-ciba.js](../data/connector.jwt-ciba.js)

These variables matter in the role-scoped JWT phases.

### `VAULT_KV_PATH`

Purpose:

- path to the static secret in Vault KV

Current role in code:

- used by the Vault KV connector paths

Typical use case:

- workshop phases where the database credentials are still static, but stored in Vault instead of in code or `.env`

---

## Vault AppRole Settings

These variables support machine-to-machine Vault authentication.

### `VAULT_ROLE_ID`

Purpose:

- public AppRole identifier

Current role in code:

- used by:
  - [data/connector.approle.js](../data/connector.approle.js)
  - [data/connector.approle-dynamic.js](../data/connector.approle-dynamic.js)
  - [data/connector.approle-rotation.js](../data/connector.approle-rotation.js)

### `VAULT_SECRET_ID`

Purpose:

- sensitive AppRole secret

Current role in code:

- used by the same AppRole connector set

These two values are central to the AppRole phases. If they are missing or stale, the AppRole connectors will fail immediately.

### `VAULT_JWT_ROLE`

Purpose:

- Vault JWT auth role name used when exchanging a Keycloak JWT for a Vault token

Current role in code:

- used by:
  - [data/connector.jwt-rotation.js](../data/connector.jwt-rotation.js)
  - [data/connector.jwt-roles.js](../data/connector.jwt-roles.js)
  - [data/connector.jwt-ciba.js](../data/connector.jwt-ciba.js)

Even though it sits near the AppRole variables in the file, it is really part of the JWT/Vault integration path.

---

## JWT And Keycloak Settings

These variables control user authentication and identity integration.

### `JWKS_URL`

Purpose:

- public key endpoint used to verify RS256 JWTs

Current role in code:

- used by [backend/auth.js](../backend/auth.js)

If this is set, the backend validates real bearer tokens against Keycloak’s JWKS.

### `JWT_ISSUER`

Purpose:

- expected JWT issuer claim

Current role in code:

- used by [backend/auth.js](../backend/auth.js)

This is optional validation, but strongly useful when using real OIDC tokens.

### `KEYCLOAK_ADDR`

Purpose:

- internal Keycloak base URL

Current role in code:

- used by:
  - [backend/server.js](../backend/server.js)
  - [backend/ciba.js](../backend/ciba.js)
  - JWT connector variants

### `KEYCLOAK_REALM`

Purpose:

- workshop realm name

Current role:

- used throughout auth proxy and CIBA code

### `KEYCLOAK_CLIENT_ID`

Purpose:

- application client identifier used for token exchange

Current role:

- used by login proxy and JWT connector flows

### `KEYCLOAK_CLIENT_SECRET`

Purpose:

- backend client secret used when talking to Keycloak

Current role:

- used by:
  - `/auth/token` proxy
  - CIBA flow
  - JWT connector variants

This is another highly sensitive value.

### `KEYCLOAK_USERNAME`
### `KEYCLOAK_PASSWORD`

Purpose:

- workshop user credentials used by some connector flows

Current role in code:

- used by:
  - [data/connector.jwt-rotation.js](../data/connector.jwt-rotation.js)
  - [data/connector.jwt-roles.js](../data/connector.jwt-roles.js)
  - [data/connector.jwt-ciba.js](../data/connector.jwt-ciba.js)

These are especially relevant in workshop/demo scenarios where the backend itself performs an identity-driven token exchange.

---

## Variables Supported By The Code But Not Required In The Current .env

The codebase supports more variables than the current root `.env` explicitly sets.

Important examples:

### `JWT_SECRET`

Supported by:

- [backend/auth.js](../backend/auth.js)

Purpose:

- dev fallback for HS256 token validation when `JWKS_URL` is not used

Current state:

- supported, but not set in the current `.env`

### `CIBA_POLL_INTERVAL`
### `CIBA_TIMEOUT`

Supported by:

- [backend/ciba.js](../backend/ciba.js)

Purpose:

- tune CIBA polling interval and timeout behavior

Current state:

- supported, but not set in the current `.env`
- backend falls back to internal defaults

### `VAULT_DB_HOST`
### `VAULT_DB_PORT`
### `VAULT_DB_NAME`

Supported by:

- AppRole rotation and JWT connector variants

Purpose:

- override database host, port, and name for Vault-issued credential flows

Current state:

- supported, but not set in the current `.env`
- code falls back to the workshop defaults such as `db` and `appdb`

### `DB_HOST`
### `DB_PORT`
### `DB_NAME`
### `DB_USER`
### `DB_PASSWORD`

Supported by:

- some JWT connector variants

Purpose:

- static DB fallback mode in some role-aware connectors

Current state:

- supported, but not used by the current root `.env`

### `VAULT_NAMESPACE`

Supported by:

- Vault CLI helper scripts such as [scripts/vault_login.sh](../scripts/vault_login.sh)

Purpose:

- namespace-aware Vault access in enterprise or multi-namespace environments

Current state:

- optional, not required for the local workshop setup

---

## Precedence And Fallback Behavior

The workshop does not rely on one universal precedence rule. Different modules use different fallbacks.

Important examples:

### Database env connector

[data/connector.env.js](../data/connector.env.js) prefers:

1. individual `POSTGRES_*` values
2. `DATABASE_URL`

### Backend pool manager

[backend/pool-manager.js](../backend/pool-manager.js) falls back to:

- `DATABASE_URL`

when connector-provided credentials are not the source of truth.

### JWT auth

[backend/auth.js](../backend/auth.js) prefers:

1. `JWKS_URL`
2. `JWT_SECRET`

If neither exists, bearer-token validation cannot work.

### Frontend Vite config

[frontend/vite.config.js](../frontend/vite.config.js) falls back to:

- `VITE_API_URL || http://backend:3000`
- `VITE_PORT || 5173`

So the stack has reasonable defaults, but the root `.env` remains the main explicit contract.

---

## Security Notes

The root `.env` is sensitive.

Based on the current file contents, it contains values such as:

- database credentials
- Vault token
- Vault AppRole secret material
- Keycloak client secret
- workshop user credentials

That means:

- it must stay gitignored
- it must not be pasted into docs
- it must not be copied into issue comments or PR descriptions
- it should not be treated as a harmless local config file

### Practical guidance

- keep `.env` out of version control
- rotate any credential that was accidentally exposed
- prefer placeholders in all documentation
- treat `VAULT_TOKEN`, `VAULT_SECRET_ID`, and `KEYCLOAK_CLIENT_SECRET` as high-impact secrets

---

## Troubleshooting

### Backend starts but `/ask` fails

Check:

- `OLLAMA_ADDR`
- Ollama container health

### Login fails through `/auth/token`

Check:

- `KEYCLOAK_ADDR`
- `KEYCLOAK_REALM`
- `KEYCLOAK_CLIENT_ID`
- `KEYCLOAK_CLIENT_SECRET`

### JWT-protected routes fail

Check:

- `JWKS_URL`
- `JWT_ISSUER`

If using dev-only HS256 validation instead, verify `JWT_SECRET`.

### Vault-backed connector fails

Check the variables appropriate to the active phase:

- `VAULT_ADDR`
- `VAULT_TOKEN`
- `VAULT_MODE`
- `VAULT_KV_PATH`
- `VAULT_DB_ROLE`

### AppRole connector fails

Check:

- `VAULT_ROLE_ID`
- `VAULT_SECRET_ID`

### JWT role-aware or CIBA connector fails

Check:

- `VAULT_JWT_ROLE`
- `KEYCLOAK_CLIENT_SECRET`
- `KEYCLOAK_USERNAME`
- `KEYCLOAK_PASSWORD`
- role-mapped variables such as:
  - `VAULT_DB_ROLE_VIEWER`
  - `VAULT_DB_ROLE_SUPPORT`
  - `VAULT_DB_ROLE_ADMIN`

### Frontend does not appear on the expected host port

Check:

- `VITE_HOST_PORT`
- `VITE_PORT`
- Compose port mapping in [docker-compose.yml](../docker-compose.yml)
