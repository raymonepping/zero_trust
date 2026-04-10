# OpenAPI And Swagger UI

**Spec location:** `backend/openapi.json`  
**Route module:** `backend/openapi-routes.js`

This document explains the OpenAPI and Swagger UI support in the Zero Trust Workshop backend.

It is written for:

- students who want a visible API reference
- engineers who want to maintain the backend contract cleanly

---

## Table Of Contents

- [Purpose](#purpose)
- [What Exists Today](#what-exists-today)
- [Endpoints](#endpoints)
- [How It Is Exposed](#how-it-is-exposed)
- [Environment Control](#environment-control)
- [Why OpenAPI Was Chosen](#why-openapi-was-chosen)
- [What The Spec Covers](#what-the-spec-covers)
- [How To Update It](#how-to-update-it)
- [Validation Script](#validation-script)
- [Useful Notes](#useful-notes)

---

## Purpose

The workshop now includes a machine-readable API contract and a browser-rendered API reference.

That gives the backend two useful capabilities:

- a canonical route definition in JSON form
- a visible docs page for students and engineers

This is useful in a workshop because the backend has:

- public routes
- optional-auth routes
- authenticated routes
- streamed responses
- CIBA-gated write flows

Those are easier to understand when the route contract is visible in one place.

---

## What Exists Today

The implementation consists of two parts:

- [backend/openapi.json](../backend/openapi.json)  
  The OpenAPI specification.

- [backend/openapi-routes.js](../backend/openapi-routes.js)  
  The Express route module that serves the spec and Swagger UI.

The backend entry point mounts the docs routes only when enabled by environment variable.

---

## Endpoints

When route exposure is enabled, the backend serves:

- `GET /openapi.json`  
  Raw OpenAPI definition.

- `GET /docs`  
  Swagger UI rendering of the OpenAPI definition.

Typical local URLs:

- `http://localhost:3000/openapi.json`
- `http://localhost:3000/docs`

---

## How It Is Exposed

The docs routes are mounted from [backend/openapi-routes.js](../backend/openapi-routes.js).

The backend does not need an extra npm package for this implementation. Instead:

- the backend serves the JSON spec directly
- `/docs` returns a small HTML page
- that page loads Swagger UI assets from a CDN
- Swagger UI reads `/openapi.json`

This keeps the backend dependency footprint small while still giving a full interactive docs page.

---

## Environment Control

The docs are gated by:

```text
EXPOSE_ROUTES
```

When:

```text
EXPOSE_ROUTES=true
```

the backend exposes:

- `/openapi.json`
- `/docs`

When the variable is unset or not `true`, those routes are not mounted.

This is useful because the workshop may want visible API docs in development while keeping them optional in other environments.

---

## Why OpenAPI Was Chosen

OpenAPI is the source of truth.

Swagger UI is only the viewer.

That is the right design here because:

- the spec is machine-readable
- the same file can be used by future tooling
- the UI is replaceable
- the backend contract remains separate from the renderer

In practical terms:

- **OpenAPI** defines the contract
- **Swagger UI** displays the contract

---

## What The Spec Covers

The current spec covers the main backend route surface, including:

- root and health
- credentials and lease health
- all read-only data endpoints
- `/ask`
- `/auth/token`
- CIBA initiation, pending, approval, status, diagnostics
- CIBA-gated order status write

It also documents important behavior such as:

- optional Bearer auth on read routes
- streamed plain-text response from `/ask`
- connector-dependent CIBA availability
- the write route living at `/orders/{id}/status`

---

## How To Update It

When you add, remove, or change backend routes, update:

1. [backend/openapi.json](../backend/openapi.json)
2. [docs/readme_routes.md](./readme_routes.md)
3. [docs/readme_backend.md](./readme_backend.md) when behavior or URLs changed

Practical rule:

- if a route changed in `server.js` or `ciba-routes.js`, assume the spec and route docs need review

---

## Validation Script

A lightweight validation helper exists at:

- [scripts/validate_openapi_docs.sh](../scripts/validate_openapi_docs.sh)

Run it from the repository root:

```bash
./scripts/validate_openapi_docs.sh
```

It checks:

- `backend/openapi.json` parses as valid JSON
- key routes exist in the OpenAPI spec
- the same routes appear in:
  - `docs/readme_routes.md`
  - `docs/readme_backend.md`

This is not a full semantic OpenAPI validator. It is a drift detector for the workshop docs and route inventory.

---

## Useful Notes

### 1. `/docs` is intentionally unauthenticated

In the current workshop setup, the docs page does not require login.

That is acceptable here because it is a teaching environment and the route exposure is env-gated.

### 2. The spec can still drift

OpenAPI helps, but only if it is updated when routes change.

That is why the validation script matters.

### 3. The UI styling is custom

The `/docs` page uses Swagger UI with workshop-specific CSS overrides for readability.

### 4. OpenAPI is a platform for later work

If you later want:

- stronger API validation
- generated clients
- richer docs workflows
- CI checks

the spec file is the right starting point.
