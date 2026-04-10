# test_routes.sh And Backend Route Reference

**Script location:** `scripts/test_routes.sh`  
**Backend route implementation:** `backend/server.js`, `backend/ciba-routes.js`

This document explains two related things:

1. what `scripts/test_routes.sh` does
2. which HTTP routes the backend currently exposes

It is written for students running the workshop labs and for engineers maintaining or extending the backend.

No sensitive values are included here. All examples use placeholders or safe local defaults.

---

## Table Of Contents

- [Purpose](#purpose)
- [What The Script Tests](#what-the-script-tests)
- [How To Use The Script](#how-to-use-the-script)
- [Supported Route Selectors](#supported-route-selectors)
- [Backend Route Groups](#backend-route-groups)
- [Public And Optional-Auth Routes](#public-and-optional-auth-routes)
- [Authenticated Routes](#authenticated-routes)
- [CIBA Routes](#ciba-routes)
- [Route Testing Strategy](#route-testing-strategy)
- [Useful Notes For Students](#useful-notes-for-students)
- [Useful Notes For Engineers](#useful-notes-for-engineers)
- [Troubleshooting](#troubleshooting)

---

## Purpose

The backend surface in this workshop changes behavior depending on:

- the active connector
- whether the caller is authenticated
- whether the connector supports CIBA write flows
- whether the connected role can read certain tables or classifications

`scripts/test_routes.sh` exists to give you a quick way to probe those routes without hand-writing every `curl` command.

It is a smoke-test tool, not a full integration test suite.

That distinction matters:

- it checks that important routes respond
- it verifies auth token retrieval
- it exercises optional-auth and authenticated reads
- it can trigger safe CIBA initiation checks when the connector supports it
- it can force lease rotation for dynamic credential phases

It does not try to fully automate every workflow end to end.

---

## What The Script Tests

The current script covers these route areas:

- root and health routes
- optional-auth data routes
- authenticated data routes
- credential metadata route
- streamed `/ask` route
- lease health and manual rotation routes
- CIBA diagnostics
- CIBA pending and initiate checks when the active connector supports delegated writes
- token retrieval through `/auth/token`

It also supports a cleanup helper for outstanding Vault database leases when `vault` CLI access is available.

---

## How To Use The Script

From the repository root:

```bash
./scripts/test_routes.sh
```

This runs the default sequence.

Useful variations:

```bash
./scripts/test_routes.sh --list-routes
./scripts/test_routes.sh --route health
./scripts/test_routes.sh --route users --route orders
./scripts/test_routes.sh --route ask --username repping --password password
./scripts/test_routes.sh --refresh-token --username repping --password password
./scripts/test_routes.sh --cleanup
```

Important options:

- `--base-url`  
  Override the backend base URL. Default: `http://localhost:3000`

- `--username`  
  Username used for `/auth/token`

- `--password`  
  Password used for `/auth/token`

- `--refresh-token`  
  Fetch a fresh access token and exit

- `--cleanup`  
  Revoke outstanding dynamic database leases and exit

- `--route`  
  Run one or more specific route selectors

- `--list-routes`  
  Print supported selectors

Environment overrides:

- `BASE_URL`
- `KC_USERNAME`
- `KC_PASSWORD`
- `QUESTION`

The `QUESTION` variable is used for the `/ask` smoke test.

Example:

```bash
QUESTION="Which user spent the most money?" ./scripts/test_routes.sh --route ask
```

---

## Supported Route Selectors

The script currently supports these selectors:

- `root`
- `health`
- `users`
- `orders`
- `preferences`
- `training`
- `tickets`
- `projects`
- `credentials`
- `ask`
- `ciba-capability`
- `ciba-pending`
- `ciba-diagnostics`
- `health-lease`
- `rotate`
- `auth-token`
- `public`
- `authenticated`
- `ciba`
- `all`

Notes:

- `ciba` is an alias for `ciba-capability`
- `public` runs the unauthenticated probes
- `authenticated` fetches a token and then runs the authenticated route set
- `all` runs the full default sequence

---

## Backend Route Groups

The backend route surface is split across:

- [backend/server.js](../backend/server.js)
- [backend/ciba-routes.js](../backend/ciba-routes.js)

The CIBA router is mounted at:

```text
/ciba
```

So a route declared in `ciba-routes.js` as:

```text
GET /pending
```

is exposed by the backend as:

```text
GET /ciba/pending
```

---

## Public And Optional-Auth Routes

These routes are either fully public or use optional authentication.

Optional authentication means:

- the route works without a Bearer token
- if a valid token is present, the backend can apply role-aware credential logic

### `GET /`

Basic database connectivity check.

Purpose:

- confirm the backend can query PostgreSQL

Typical response:

```json
{
  "status": "ok",
  "message": "database is connected"
}
```

### `GET /health`

High-level backend health endpoint.

Purpose:

- check database connectivity
- report backend mode
- report Vault probe status when Vault is in use

Useful for:

- container health checks
- quick operational diagnostics

### `GET /users`

Returns user records.

Auth model:

- works without a token
- can use role-aware context when a token is present

### `GET /orders`

Returns order records joined to user data.

Auth model:

- optional auth

Notes:

- in some restricted-role scenarios, the backend may return an empty array instead of failing with a raw permission error

### `GET /preferences`

Returns user preference data.

Auth model:

- optional auth

Notes:

- trust-level filtering applies to classification visibility

### `GET /training`

Returns training and certification data.

Auth model:

- optional auth

### `GET /tickets`

Returns support ticket data.

Auth model:

- optional auth

### `GET /projects`

Returns project assignment and budget data.

Auth model:

- optional auth

### `GET /credentials`

Returns metadata about the currently active connector and database credential state.

This is one of the most useful workshop routes because it shows:

- active connector source
- connector phase
- whether CIBA write is enabled
- path, role, TTL, and lease metadata when available
- trust level
- allowed classifications
- pool status and rotation count

The password field is intentionally masked.

### `GET /health/lease`

Returns lease and rotation health for current credentials.

This is most useful in:

- dynamic AppRole phases
- JWT dynamic phases
- rotation phases
- Vault Agent phases

If the active connector does not use live renewable credentials, the route may report:

```json
{
  "status": "no-credentials"
}
```

### `GET /ciba/diagnostics`

Returns CIBA subsystem diagnostics.

This route is useful even outside the active CIBA phase because it reveals:

- whether CIBA write support is enabled
- current in-memory CIBA manager state
- tracked sessions

The script includes this route in both public and CIBA checks because it is a low-risk diagnostic endpoint.

---

## Authenticated Routes

These routes require a valid token directly or are most meaningful with one.

### `POST /auth/token`

Exchanges username and password for a Keycloak-backed access token.

This is a backend proxy route. The browser or test script talks to the backend, and the backend talks to Keycloak.

Purpose:

- keep Keycloak on internal Docker networking
- simplify frontend auth

Expected request body:

```json
{
  "username": "student-user",
  "password": "student-password"
}
```

Typical response shape:

```json
{
  "access_token": "<jwt>",
  "expires_in": 300
}
```

### `POST /ask`

Runs the natural-language query flow.

Expected request body:

```json
{
  "question": "Which user spent the most money?"
}
```

Behavior:

- optional auth, but role-aware if authenticated
- backend selects relevant datasets
- backend applies trust-level filtering
- backend queries the data
- backend builds an LLM prompt
- backend streams plain-text output back to the caller

This route returns streamed text, not a normal JSON object.

That is why the script treats it as a smoke test rather than trying to validate a rigid response structure.

### `POST /health/lease/rotate`

Forces lease rotation through the connector and pool manager.

Expected request body:

```json
{}
```

Optional targeted form:

```json
{
  "role": "viewer-read"
}
```

Use this carefully during labs because it actively rotates credentials and pools.

The script includes it because it is part of the workshop’s dynamic-credential story.

---

## CIBA Routes

These routes live in [backend/ciba-routes.js](../backend/ciba-routes.js) and are mounted under `/ciba`.

Important distinction:

- some CIBA routes are frontend-facing
- one route is Keycloak-facing
- one write route lives outside `/ciba`

### `POST /ciba/request`

Called by Keycloak’s HTTP authentication channel provider.

This is not a student-facing route and should not be used as a normal manual test endpoint.

Purpose:

- receive delegated authentication requests from Keycloak

Key behavior:

- expects a Keycloak bearer token
- must acknowledge with HTTP `201`

### `POST /ciba/initiate`

Starts a delegated approval flow for an elevated write action.

Requires:

- valid user JWT
- active connector with `ciba_write` capability

Expected request body:

```json
{
  "orderId": 1,
  "newStatus": "shipped"
}
```

The script uses this route as a safe capability smoke test.

### `GET /ciba/pending`

Returns pending CIBA approval requests for the authenticated user.

Requires:

- valid user JWT
- active CIBA-capable connector

### `POST /ciba/approve`

Approves or denies a pending CIBA request.

Expected request body:

```json
{
  "requestId": "<pending-request-id>",
  "decision": "SUCCEED"
}
```

or:

```json
{
  "requestId": "<pending-request-id>",
  "decision": "CANCELLED"
}
```

This route is intentionally not exercised automatically by `test_routes.sh` because it can move a live delegated approval forward.

### `GET /ciba/status/:sessionId`

Returns the status of a previously initiated CIBA session.

Requires:

- valid user JWT
- ownership of the session

Common states include:

- `polling`
- `approved`
- `denied`
- `expired`
- `executed`

### `POST /orders/:id/status`

This is the actual write endpoint gated by CIBA approval.

Important:

- the route path is `/orders/:id/status`
- it is implemented in `ciba-routes.js`
- it is not mounted under `/ciba`

Expected request body:

```json
{
  "newStatus": "shipped",
  "cibaSessionId": "ciba-1-..."
}
```

Requirements:

1. authenticated user
2. approved CIBA session
3. session matches the requested action
4. write-scoped credential issuance succeeds

This endpoint is intentionally not executed by `test_routes.sh` because it changes application data.

---

## Route Testing Strategy

The script does not treat all routes the same way.

### Safe smoke-tested automatically

- `GET /`
- `GET /health`
- `GET /users`
- `GET /orders`
- `GET /preferences`
- `GET /training`
- `GET /tickets`
- `GET /projects`
- `GET /credentials`
- `GET /health/lease`
- `GET /ciba/diagnostics`
- `POST /auth/token`
- `POST /ask`
- `POST /health/lease/rotate`
- `GET /ciba/pending` when CIBA is enabled
- `POST /ciba/initiate` when CIBA is enabled

### Documented but not fully automated because of side effects or external workflow coupling

- `POST /ciba/request`
- `POST /ciba/approve`
- `GET /ciba/status/:sessionId`
- `POST /orders/:id/status`

That is the right balance for this workshop. You want route confidence without a script accidentally mutating business data or racing a real approval flow.

---

## Useful Notes For Students

### 1. Optional auth is part of the lesson

Several routes work without a token. That is intentional.

The workshop is showing how:

- the same route can behave differently depending on caller identity
- trust level and role scoping are layered controls

### 2. Empty arrays can be meaningful

If a route returns `[]`, that does not always mean the system is broken.

It may mean:

- your role lacks permission to read that dataset
- classification filtering removed all visible rows

### 3. `/credentials` is your friend

When something looks wrong, inspect:

```bash
./scripts/test_routes.sh --route credentials
```

That usually explains:

- which connector is active
- whether CIBA is enabled
- whether the backend is using dynamic credentials

### 4. `/ask` is filtered by the same trust model

The LLM does not bypass the security model. It only sees what the backend chooses to include in its prompt context.

---

## Useful Notes For Engineers

### 1. Route behavior is connector-sensitive

Do not assume the same operational behavior across:

- `wired`
- `env`
- `vault`
- `approle-dynamic`
- `agent-dynamic`
- `jwt-roles`
- `jwt-ciba`

The route paths remain stable, but the credential acquisition and trust behavior behind them changes substantially.

### 2. The read routes are intentionally uniform

The read endpoints follow a consistent pattern:

- build user context
- resolve Vault role when available
- query through `poolManager`
- catch permission-denied cases selectively

That consistency makes the backend easier to extend.

### 3. The route script is a smoke-test harness

It is not trying to validate every response field or HTTP edge case. If you need stronger assertions, add a dedicated automated test layer rather than turning this script into a brittle test framework.

### 4. The CIBA write endpoint is separated from the CIBA router prefix

That is easy to miss:

- approval flow routes are under `/ciba/*`
- the actual write route is `/orders/:id/status`

Keep that distinction clear when documenting or extending the flow.

---

## Troubleshooting

### `ERROR: failed to obtain access token`

Check:

- backend is running
- Keycloak is running
- the user exists
- the provided credentials are correct

### `/ask` returns an error or hangs

Check:

- backend health
- Ollama health
- connector and data path state

Remember that `/ask` is streamed text, not a standard JSON response.

### `GET /ciba/pending` or `POST /ciba/initiate` returns 404

That usually means:

- the active connector does not have `ciba_write` enabled

This is expected outside the JWT+CIBA phase.

### Lease routes are empty or say `no-credentials`

That is normal for static or non-renewable connector phases.

The route is most meaningful in dynamic credential phases.

### `--cleanup` fails

The cleanup helper requires:

- `vault` CLI installed
- valid Vault environment setup in your shell

It is an operator helper, not a pure HTTP route test.
