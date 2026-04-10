# frontend/ — Vite Frontend Overview

**Location:** `frontend/`

This document explains the Vite-based frontend used in the Zero Trust Workshop. It is written for students who need to understand how the labs behave from the browser, and for engineers who may want to extend, debug, or review the implementation.

The frontend is the workshop's user-facing shell. It does not talk to PostgreSQL, Vault, Keycloak, or OpenLDAP directly. It only talks to the backend API and presents:

- login state
- connector and Vault health
- trust-level and classification visibility
- natural-language query input and streamed answers
- CIBA-gated delegated writes

The frontend stays mostly constant across the lab progression. What changes from phase to phase is what the backend reports and what actions the current connector enables.

---

## Table Of Contents

- [Purpose](#purpose)
- [Frontend Module Layout](#frontend-module-layout)
- [Runtime Model](#runtime-model)
- [How The Frontend Talks To The Backend](#how-the-frontend-talks-to-the-backend)
- [Application State Model](#application-state-model)
- [Authentication Flow](#authentication-flow)
- [Health And Credential Visibility](#health-and-credential-visibility)
- [Natural Language Query Flow](#natural-language-query-flow)
- [CIBA Delegated Write Flow](#ciba-delegated-write-flow)
- [UI Structure](#ui-structure)
- [Styling Model](#styling-model)
- [Container And Development Behavior](#container-and-development-behavior)
- [Environment And Configuration](#environment-and-configuration)
- [Useful Engineering Notes](#useful-engineering-notes)
- [Troubleshooting](#troubleshooting)

---

## Purpose

The frontend has three jobs:

1. Present the current trust posture of the running workshop.
2. Let the user authenticate and query the system safely.
3. Surface when elevated operations require explicit approval.

This is why the UI combines:

- a login bar
- system readiness and Vault status panels
- a trust/classification panel
- a prompt-driven query interface
- a conditional delegated write panel for the CIBA phase

It is not a general-purpose admin console. It is a lab interface designed to make the connector progression visible.

---

## Frontend Module Layout

The `frontend/` directory is intentionally small.

- [frontend/package.json](../frontend/package.json)  
  Package metadata, React/Vite dependencies, and the dev/build scripts.

- [frontend/vite.config.js](../frontend/vite.config.js)  
  Vite config, dev server binding, and proxy rules for `/api/*`.

- [frontend/Dockerfile](../frontend/Dockerfile)  
  Container image used by Docker Compose for the live frontend.

- [frontend/index.html](../frontend/index.html)  
  Root HTML shell that Vite uses to mount the React app.

- [frontend/src/main.jsx](../frontend/src/main.jsx)  
  React entry point. Mounts `App` inside `StrictMode`.

- [frontend/src/App.jsx](../frontend/src/App.jsx)  
  The main application component. Nearly all frontend behavior lives here.

- [frontend/src/index.css](../frontend/src/index.css)  
  Global styles, layout, cards, forms, status badges, and responsive behavior.

---

## Runtime Model

The frontend runs as:

- React 19
- Vite 6
- a single-page application
- usually inside a Docker container during the workshop

From [frontend/package.json](../frontend/package.json):

```json
{
  "scripts": {
    "dev": "sh -c 'echo \"Frontend host URL: http://localhost:${VITE_HOST_PORT:-${VITE_PORT:-5173}}/\"; vite --host --logLevel error'",
    "build": "vite build",
    "preview": "vite preview"
  }
}
```

This means:

- `npm run dev` starts the Vite dev server and binds on all interfaces
- `npm run build` produces a static production bundle
- `npm run preview` serves the built output locally

The React entry point is minimal. [frontend/src/main.jsx](../frontend/src/main.jsx) mounts one root component:

```jsx
createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
  </StrictMode>
);
```

So in practical terms:

- `App.jsx` is the application
- there is no route system
- there is no client-side state library
- local component state and effects drive the whole UI

---

## How The Frontend Talks To The Backend

The frontend does not embed backend URLs directly in every fetch call. Instead, Vite proxies `/api/*` traffic during development and in the containerized workshop setup.

From [frontend/vite.config.js](../frontend/vite.config.js):

- `/api/auth` proxies to the backend with no timeout
- `/api/ask` proxies to the backend with no timeout
- `/api` proxies to the backend with a shorter timeout

This split exists for a reason:

- login may need longer than a trivial health call
- streamed `/api/ask` responses must stay open
- short-lived API routes should fail quickly when the backend is unavailable

The proxy also normalizes some backend-unavailable failures into JSON:

```json
{
  "error": "backend_unavailable",
  "detail": "..."
}
```

That makes local debugging and workshop demos easier because the browser gets a structured error instead of a generic proxy failure.

---

## Application State Model

Most frontend behavior lives in [frontend/src/App.jsx](../frontend/src/App.jsx).

The component tracks several state groups:

- authentication state
  - username
  - password
  - Bearer token
  - token expiry
- system readiness state
  - backend health
  - database status
  - Vault metadata
- query state
  - current question
  - loading flag
  - streamed answer text
  - latest answer metadata
- CIBA state
  - order id
  - target status
  - current session id
  - pending approvals
  - approval status
  - execution result

This is a deliberate design choice:

- the app is small enough to avoid Redux or another client store
- workshop behavior is easier to read when all core logic is in one place
- connector-specific UI changes can be added without chasing state through a larger framework

---

## Authentication Flow

The frontend handles user login against the backend, not directly against Keycloak.

### Login request

When the user signs in, the frontend sends:

```text
POST /api/auth/token
```

with the submitted username and password.

The backend returns a token payload. The frontend stores the access token in `sessionStorage`, not `localStorage`.

That matters because:

- the token survives page refresh within the same tab session
- the token does not persist as broadly as long-lived local browser storage

### Expiry handling

The frontend decodes the JWT payload client-side to determine the `exp` value. It uses that to:

- reject expired tokens from request headers
- clear stale auth state when needed
- trigger token refresh before expiry

### Refresh behavior

The app refreshes the token at roughly 80% of its TTL by repeating the credential-based token request while the user session is active.

That keeps the student workflow smooth during labs:

- fewer forced re-logins while switching connectors
- fewer confusing auth failures during long demos

### Auth-aware UI behavior

When logged in, the UI shows:

- signed-in user status
- sign-out control
- JWT-scoped connector behavior when applicable
- the CIBA write panel when the current phase supports it

When logged out:

- the signed-in banner disappears
- authenticated requests lose their Bearer header
- the CIBA panel is not rendered

---

## Health And Credential Visibility

The frontend polls the backend for operational state so students can see how each connector phase behaves.

### Health polling

The app polls:

```text
GET /api/health
```

every 10 seconds.

This drives the readiness card, which shows information such as:

- PostgreSQL connectivity
- Vault connectivity
- current connector source
- current trust/access level

### Credential metadata polling

The app also polls:

```text
GET /api/credentials
```

every 15 seconds.

This is how the UI learns:

- which connector source is active
- whether the credential is static or dynamic
- whether rotation is in effect
- whether JWT role mapping is in effect
- whether CIBA write capability is available

### Source labeling

`App.jsx` contains a source-to-label map for the Vault status panel. This translates backend connector identifiers into user-facing labels such as:

- `WIRED`
- `ENV`
- `KV`
- `APPROLE`
- `DYNAMIC`
- `ROTATION`
- `JWT`
- `JWT+ROLES`
- `JWT+CIBA`

This is important for the lab because the UI is one of the main places students verify that a connector switch actually took effect.

### Trust and classification visualization

The frontend also presents:

- current access level
- number of visible classifications
- a progress meter
- per-classification visibility chips

This turns a backend security model into something visually inspectable. Instead of just reading logs, students can see data visibility expand as they progress through the workshop.

---

## Natural Language Query Flow

The main interaction in the frontend is the question composer.

### Suggested prompts

The app provides several built-in prompt chips to help students exercise the system without inventing a query from scratch.

Examples include prompts about:

- user purchases
- interests
- spend analysis
- security clearance

### Ask request

When the user submits a question, the frontend sends:

```text
POST /api/ask
```

The backend responds as a text stream, and the frontend reads it incrementally using the browser `ReadableStream` API.

### Streaming response behavior

The frontend:

- clears any stale answer text before a new request starts
- appends streamed chunks as they arrive
- keeps the latest response visible in the answer panel
- exposes copy and clear controls for the latest answer

This gives the workshop a more interactive feel than waiting for a single large JSON response at the end.

### Error handling

If the stream or request fails, the app shows a user-facing failure state instead of leaving the UI hanging.

This matters because several workshop phases involve intentionally changing backend behavior. The frontend should degrade cleanly when a connector misconfiguration or backend outage occurs.

---

## CIBA Delegated Write Flow

The most advanced frontend workflow is the delegated write panel used in the CIBA phase.

This panel is intentionally conditional.

It only appears when:

- the user is logged in

and it is only actionable when:

- the backend reports `ciba_write` capability for the current connector

### What the panel does

The panel lets the user:

- choose an order id
- choose a target status
- initiate a delegated write request
- approve the request

### API sequence

The frontend coordinates several backend routes:

1. `POST /api/ciba/initiate`  
   Starts the backchannel auth request.

2. `GET /api/ciba/pending`  
   Polls for pending approval requests.

3. `POST /api/ciba/approve`  
   Sends the approval decision.

4. `GET /api/ciba/status/:sessionId`  
   Polls the session state.

5. `POST /api/ciba/orders/:id/status`  
   Executes the actual write after approval succeeds.

### Why this matters in the workshop

This panel demonstrates a security model that is very different from the earlier phases:

- the user can read without elevated authority
- a write requires explicit approval
- the approval leads to a short-lived write credential
- the elevated capability is narrow and temporary

From a teaching perspective, this is the point where the frontend stops being only a read/query shell and becomes a visual proof of delegated authorization.

---

## UI Structure

The main screen in [frontend/src/App.jsx](../frontend/src/App.jsx) is built around a few major sections.

### Top session bar

Shows either:

- current signed-in user and sign-out action

or:

- the login form and sign-in action

### Hero section

Contains:

- workshop identity copy
- a short explanation of the current experience
- the conditional CIBA delegated write panel beneath the hero copy

### System readiness panel

Shows:

- PostgreSQL status
- Vault connector state
- connector label and capability hints

### Data access panel

Shows:

- current trust level
- visible classification count
- progress meter
- classification badges

### Ask panel

Contains:

- suggested prompt chips
- question text area
- submit button
- latest streamed response panel

This layout is intentionally compact. Students can see trust posture, query interface, and delegated write controls on one screen.

---

## Styling Model

All styling currently lives in [frontend/src/index.css](../frontend/src/index.css).

The design language is consistent with the workshop theme:

- dark background
- warm gold/orange highlight palette
- mono labels for status and metadata
- high-contrast cards for system state

Some useful implementation notes:

- CSS custom properties define the color system and radii
- the layout uses grid and flex instead of a component library
- the hero area and status cards are responsive
- the CIBA panel uses wrapped controls so it can compress cleanly on smaller widths
- state badges use dedicated modifier classes for ready, polling, approved, executed, disabled, denied, and expired states

This is a hand-rolled UI rather than a framework-styled dashboard. That keeps the workshop easier to inspect and modify.

---

## Container And Development Behavior

The frontend is usually run via Docker Compose, not just with a local `npm run dev`.

From [frontend/Dockerfile](../frontend/Dockerfile):

- base image: `node:25.8.2-alpine3.23`
- installs `curl`
- installs dependencies with `npm ci`
- exposes port `5173`
- starts with `npm run --silent dev`

From [docker-compose.yml](../docker-compose.yml):

- `./frontend` is bind-mounted into `/app`
- `/app/node_modules` is kept inside the container so the bind mount does not overwrite dependencies
- the frontend depends on backend health
- the host port defaults to `8088`
- the internal Vite port defaults to `5173`

This setup means:

- local file edits appear inside the running container immediately
- the running UI usually matches the checked-out source tree
- rebuilding the image is not required for normal frontend edits

For students, that keeps the lab simple. For engineers, it makes iteration fast.

---

## Environment And Configuration

The frontend uses a small set of runtime variables.

### `VITE_API_URL`

Default in Compose:

```text
http://backend:3000
```

Used by Vite's proxy as the backend target.

### `VITE_PORT`

Default:

```text
5173
```

This is the internal Vite dev server port inside the container.

### `VITE_HOST_PORT`

Default:

```text
8088
```

This is the host port students usually open in the browser.

### Practical note

The browser typically reaches:

```text
http://localhost:8088
```

while the frontend container proxies API traffic to:

```text
http://backend:3000
```

inside Docker networking.

---

## Useful Engineering Notes

### 1. The frontend is intentionally thin

Most security logic lives in the backend. The frontend mainly reflects backend state and triggers well-defined API flows.

That is the correct design for this workshop because:

- the browser should not own trust decisions
- connector behavior belongs on the server side
- students should be able to swap security models without rewriting the UI

### 2. Connector awareness is metadata-driven

The frontend does not infer everything from visuals. It relies on backend-reported source and capability metadata.

That keeps the UI extensible. If you add a new connector mode, the frontend usually only needs:

- a source label mapping
- optional conditional UI for new capabilities

### 3. The app is stateful enough to matter

Even though this is a small React app, it has real session, polling, streaming, and approval workflows. Changes should be tested carefully across:

- logged-out state
- logged-in read-only state
- JWT role-aware state
- CIBA-enabled write state

### 4. `sessionStorage` is a deliberate tradeoff

It is not a replacement for secure browser auth architecture in a production application. It is a pragmatic workshop choice that keeps the demo simple while avoiding unnecessarily persistent auth state.

---

## Troubleshooting

### Frontend loads but API calls fail

Check:

- backend container health
- Vite proxy target configuration
- browser devtools network tab

If the backend is down, the proxy may return a structured `backend_unavailable` error.

### Frontend container shows stale code

In the workshop, the `frontend` service bind-mounts `./frontend`, so source edits should appear quickly. If they do not:

- refresh the browser
- restart the frontend container

### Login succeeds but CIBA panel is missing

Check:

- the user is actually logged in
- the active connector is the CIBA-capable JWT mode
- backend `/api/credentials` metadata reports `ciba_write`

The panel is intentionally hidden for logged-out users and disabled for non-CIBA connector modes.

### Ask requests hang or fail

Check:

- backend health
- Ollama availability
- proxy behavior for `/api/ask`

Remember that `/api/ask` is streamed. Failures may look different from normal JSON endpoint failures.

### Connector label in the UI looks wrong

If a new connector was added but the UI label does not match, update the source metadata mapping in [frontend/src/App.jsx](../frontend/src/App.jsx).

That mapping is what turns backend source identifiers into the readiness-panel badge text.
