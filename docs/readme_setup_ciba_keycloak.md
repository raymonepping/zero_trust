# setup_ciba_keycloak.sh — Keycloak CIBA Configuration Script

**Location:** `scripts/setup_ciba_keycloak.sh`
**Workshop phase:** Phase 7 (final phase)
**Run after:** `setup_keycloak.sh` and `setup_ciba.sh`
**Run before:** switching to the `jwt-ciba` connector

This script is the second half of Phase 7 setup. Where `setup_ciba.sh` configured Vault with a write-scoped credential role, this script configures **Keycloak** to understand and serve CIBA requests. It enables the CIBA grant on the backend client, sets realm-level policies, and verifies the backchannel authentication endpoint is correctly advertised.

---

## What CIBA requires from Keycloak

CIBA (Client-Initiated Backchannel Authentication) is an OpenID Connect extension. By default, Keycloak does not have it enabled — you must opt in at both the **realm level** and the **client level**. This script handles both.

Keycloak's role in the CIBA flow:

```
Backend initiates → POST /realms/zero-trust/protocol/openid-connect/ext/ciba/auth
                              ↓
             Keycloak creates a pending auth request (auth_req_id)
                              ↓
             Keycloak POSTs to backend: POST /ciba/request
             (AD delegation — "please authenticate this user")
                              ↓
             Backend stores the pending request; user sees approval prompt
                              ↓
             User approves → backend sends callback to Keycloak
                              ↓
             Backend polls Keycloak token endpoint until token arrives
                              ↓
             Token used to request write credential from Vault
```

Without running this script, Keycloak does not know CIBA exists, the backchannel endpoint is not advertised, and the backend client is not allowed to use the CIBA grant type.

---

## Configuration defaults

```bash
KEYCLOAK_URL="${KC_URL:-http://localhost:8080}"
ADMIN_USER="${KC_ADMIN_USER:-admin}"
ADMIN_PASS="${KC_ADMIN_PASS:-admin}"
KEYCLOAK_CONTAINER="${KC_CONTAINER:-zero_trust_keycloak}"
TARGET_REALM="zero-trust"
BACKEND_CLIENT_ID="backend"

CIBA_MODE="poll"
CIBA_EXPIRES_IN="120"
CIBA_INTERVAL="5"
CIBA_USER_HINT="login_hint"
```

All connection parameters can be overridden via environment variables, matching the pattern from `setup_keycloak.sh`. The CIBA policy values are fixed for the workshop but defined as named variables at the top so they are easy to find and understand.

| Variable | Value | Meaning |
|----------|-------|---------|
| `CIBA_MODE` | `poll` | The backend polls Keycloak for a token after user approval |
| `CIBA_EXPIRES_IN` | `120` | The CIBA request expires after 120 seconds if not approved |
| `CIBA_INTERVAL` | `5` | The backend polls every 5 seconds |
| `CIBA_USER_HINT` | `login_hint` | How the user is identified in the CIBA request (by username) |

### CIBA delivery modes explained

Keycloak supports three CIBA token delivery modes:

| Mode | How the token is delivered |
|------|--------------------------|
| `poll` | Client polls the token endpoint repeatedly until the token is ready |
| `ping` | Keycloak sends a notification to a pre-registered URL, then client fetches the token |
| `push` | Keycloak pushes the token directly to the client's endpoint |

The workshop uses `poll` — it is the simplest to implement and does not require a separate notification endpoint. The backend calls Keycloak's token endpoint every 5 seconds until the user has approved and the token is available.

---

## Command-line flags

```
-u, --url URL           Keycloak base URL
-U, --admin-user USER   Admin username
-P, --admin-pass PASS   Admin password
-c, --container NAME    Docker container name
-h, --help              Show help
```

---

## What the script does — step by step

### Pre-flight checks

```bash
command -v docker >/dev/null 2>&1 || fail "docker not found"
command -v jq     >/dev/null 2>&1 || fail "jq not found"
command -v curl   >/dev/null 2>&1 || fail "curl not found"
docker inspect "${KEYCLOAK_CONTAINER}" >/dev/null 2>&1 || fail "..."
```

Three CLI tools are required:
- `docker` — to run `kcadm` commands inside the Keycloak container
- `jq` — to parse JSON responses from the Keycloak Admin API
- `curl` — to query the OIDC discovery endpoint and send the smoke test CIBA request

The Keycloak container must be running before proceeding.

---

### Step 1 — Authenticate to Keycloak Admin

```bash
kcadm config credentials \
  --server  "${KEYCLOAK_URL}" \
  --realm   master \
  --user    "${ADMIN_USER}" \
  --password "${ADMIN_PASS}"
```

Logs in to Keycloak's `master` realm using the bootstrap admin account. This is identical to `setup_keycloak.sh` — the admin session token is cached inside the container for subsequent `kcadm` calls.

---

### Step 2 — Verify the realm exists

```bash
kcadm get "realms/${TARGET_REALM}" >/dev/null 2>&1 || fail "..."
```

Confirms the `zero-trust` realm created by `setup_keycloak.sh` exists. If it does not, there is no point continuing — the CIBA configuration lives inside this realm.

This is a defensive check, not a creation step. The realm is not created here; that belongs to `setup_keycloak.sh`.

---

### Step 3 — Configure the realm CIBA policy

```bash
kcadm update "realms/${TARGET_REALM}" \
  -s "attributes.\"cibaBackchannelTokenDeliveryMode\"=poll" \
  -s "attributes.\"cibaExpiresIn\"=120" \
  -s "attributes.\"cibaInterval\"=5" \
  -s "attributes.\"cibaAuthRequestedUserHint\"=login_hint"
```

Sets four CIBA attributes on the `zero-trust` realm. These are realm-wide defaults — all clients using CIBA in this realm will inherit them unless overridden at the client level.

**`cibaBackchannelTokenDeliveryMode=poll`**
Tells Keycloak that clients will poll for tokens rather than expecting Keycloak to push or ping them. Keycloak will hold the token until the client fetches it.

**`cibaExpiresIn=120`**
The CIBA authentication request is valid for 120 seconds. If the user does not approve within two minutes, the request expires and the backend receives an `expired_token` error on the next poll.

**`cibaInterval=5`**
The minimum time (in seconds) between poll attempts. The backend should not poll more frequently than this — Keycloak will rate-limit it. The workshop's `ciba.js` defaults to 5 seconds, matching this value.

**`cibaAuthRequestedUserHint=login_hint`**
Specifies how the CIBA request identifies the user to be authenticated. `login_hint` means the request includes the user's login name as a plain string. The alternative is `id_token_hint` (a full JWT) or `phone_number_hint`.

In the workshop, the backend sends `login_hint=repping` (or whichever user is logged in) and Keycloak knows which user needs to approve.

---

### Step 4 — Enable the CIBA grant on the backend client

```bash
CLIENT_UUID=$(kcadm get clients -r "${TARGET_REALM}" --fields clientId,id \
  | jq -er ".[] | select(.clientId==\"backend\") | .id")

kcadm update "clients/${CLIENT_UUID}" -r "${TARGET_REALM}" \
  -s "attributes.\"oidc.ciba.grant.enabled\"=true"
```

Looks up the `backend` client's internal UUID (Keycloak requires UUIDs for sub-resource operations), then enables the CIBA grant type on it.

By default, even after the realm policy is set, individual clients must opt in to CIBA. Setting `oidc.ciba.grant.enabled=true` tells Keycloak that the `backend` client is allowed to initiate CIBA requests. Without this, every CIBA initiation attempt from the backend returns an `unauthorized_client` error.

---

### Step 5 — Retrieve the client secret

```bash
CLIENT_SECRET=$(kcadm get "clients/${CLIENT_UUID}/client-secret" -r "${TARGET_REALM}" \
  | jq -er '.value')
```

Fetches the `backend` client's auto-generated secret, which is needed for the smoke test in step 7. The secret is not printed in output — it is only held in a local variable for the duration of the script.

> The `backend` client secret should already be in your `.env` file as `KEYCLOAK_CLIENT_SECRET` from when you ran `setup_keycloak.sh`. This step re-fetches it internally for the test without exposing it.

---

### Step 6 — Verify the CIBA endpoint is advertised

```bash
DISCOVERY=$(curl -sf \
  "${HOST_KC_URL}/realms/${TARGET_REALM}/.well-known/openid-configuration")

CIBA_ENDPOINT=$(echo "${DISCOVERY}" | jq -r '.backchannel_authentication_endpoint // empty')
```

Every OIDC provider publishes a **discovery document** at `/.well-known/openid-configuration`. This JSON document lists all the endpoints and capabilities the provider supports. Once CIBA is enabled, Keycloak adds:

```json
{
  "backchannel_authentication_endpoint": "https://.../ext/ciba/auth",
  "backchannel_token_delivery_modes_supported": ["poll"],
  "backchannel_authentication_request_signing_alg_values_supported": [...]
}
```

If `backchannel_authentication_endpoint` is absent, CIBA is not properly enabled and any CIBA initiation attempt will fail. This check catches misconfiguration before the connector is activated.

The script also queries `backchannel_token_delivery_modes_supported` and prints the list — confirming `poll` is among the supported modes.

> **Note:** The script uses port 8082 (the published host port) for curl, since the Keycloak container does not have `curl` installed and must be queried from the host.

---

### Step 7 — Smoke test: send a CIBA auth request

```bash
CIBA_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "${HOST_KC_URL}/realms/${TARGET_REALM}/protocol/openid-connect/ext/ciba/auth" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=backend" \
  -d "client_secret=***" \
  -d "login_hint=repping" \
  -d "scope=openid" \
  -d "binding_message=Approve+order+update")
```

Sends a real CIBA authentication request to Keycloak and checks the HTTP response code. The script explicitly handles four expected outcomes:

| HTTP code | Meaning | Action |
|-----------|---------|--------|
| `200` | Full success — Keycloak accepted the request and the AD handler responded | `ok` |
| `503` | Keycloak accepted the request format but the backend AD handler is not running yet | `ok` — expected at this stage |
| `400` | Keycloak accepted the request but the backend callback endpoint is not ready | `ok` — expected at this stage |
| `401` | Wrong client credentials | `fail` — check the client secret |
| `000` | Could not reach Keycloak at all | `fail` — Keycloak not running |

The `503` and `400` responses are treated as success at this point. The CIBA Keycloak configuration is correct — Keycloak is processing the request and trying to reach the backend's `/ciba/request` endpoint. The backend's AD handler route will be in place once the `jwt-ciba` connector is active.

**The `binding_message`** is a short human-readable string shown to the user in the approval prompt: "What are you approving?" In production this would say something like `Approve order #42 → shipped`. It provides context so the user knows exactly what they are consenting to.

---

### Final summary output

```
────────────────────────────────────────────────────────────
 Keycloak CIBA Configuration Complete
 Realm             : zero-trust
 Client            : backend
 Delivery mode     : poll
 Request expires   : 120s
 Poll interval     : 5s
 User hint         : login_hint
 CIBA endpoint     : https://.../ext/ciba/auth
────────────────────────────────────────────────────────────
```

The script also prints an important reminder about the Keycloak SPI argument.

---

## The Keycloak SPI argument — critical prerequisite

CIBA in Keycloak requires a special startup argument that tells it where to send authentication delegation requests (the "AD handler" URL):

```yaml
command: >-
  start-dev
  --spi-ciba-auth-channel-ciba-http-auth-channel-http-authentication-channel-uri=http://backend:3000/ciba/request
```

This is already configured in the workshop's `docker-compose.yml`. Without this argument, Keycloak accepts CIBA initiation but has nowhere to delegate the authentication request — the flow never reaches the backend.

What this argument does: when Keycloak receives a CIBA auth request, it needs to ask an **Authentication Device (AD) handler** to prompt the user. In this workshop, the backend's `/ciba/request` endpoint *is* the AD handler. Keycloak POSTs the pending request there, the backend stores it, and the frontend polls for it to show the user an approval prompt.

---

## How this fits with `docker-compose.yml`

The full CIBA chain across all services:

```
Keycloak (port 8082)
  └─ SPI arg → http://backend:3000/ciba/request   (AD handler)
  └─ CIBA endpoint: /realms/zero-trust/protocol/openid-connect/ext/ciba/auth

Backend (port 3000)
  └─ POST /ciba/request     ← receives delegation from Keycloak
  └─ POST /ciba/initiate    ← called by frontend to start CIBA flow
  └─ GET  /ciba/pending     ← frontend polls for pending approvals
  └─ POST /ciba/approve     ← user approves/denies via frontend
  └─ GET  /ciba/status/:id  ← frontend polls session status
  └─ POST /orders/:id/status ← write endpoint, requires completed CIBA session
```

All communication between Keycloak and the backend uses the internal Docker network (`net-data`). The backend's published port 3000 is not used for this — Keycloak reaches the backend at `http://backend:3000` directly.

---

## Complete Phase 7 setup sequence

```bash
# 1. Ensure phases 02 and 04 of setup_vault.sh are complete
./scripts/setup_vault.sh --phase 02
./scripts/setup_vault.sh --phase 04

# 2. Configure Vault with the write-scoped role
./scripts/setup_vault.sh --phase 04   # if not done
./scripts/setup_ciba.sh

# 3. Configure Keycloak CIBA (this script)
./scripts/setup_ciba_keycloak.sh

# 4. Switch to the CIBA connector
./scripts/switch_connector.sh --replace-with jwt-ciba

# 5. Run the end-to-end test
./scripts/test_ciba.sh
```

---

## Prerequisites

| Requirement | Why |
|-------------|-----|
| `docker` | Runs `kcadm` inside the Keycloak container |
| `jq` | Parses Keycloak Admin API responses |
| `curl` | Queries the OIDC discovery endpoint and sends the smoke test |
| `setup_keycloak.sh` complete | Realm and backend client must exist |
| `setup_ciba.sh` complete | Vault `support-write` role must exist |
| Keycloak container running with SPI arg | CIBA delegation requires the startup flag |

---

## Troubleshooting

**`Realm 'zero-trust' not found`**
Run `setup_keycloak.sh` first to create the realm and clients.

**`Client 'backend' not found`**
Same cause — `setup_keycloak.sh` creates the `backend` client. Run it first.

**Smoke test returns HTTP 401**
The client secret retrieved in step 5 does not match what Keycloak expects. This can happen if the client secret was rotated. Check `KEYCLOAK_CLIENT_SECRET` in your `.env` matches what `setup_keycloak.sh` last printed.

**`CIBA endpoint not found in OIDC discovery`**
The realm CIBA policy in step 3 was not applied successfully, or Keycloak needs a restart to pick it up. Check `docker logs zero_trust_keycloak` for errors.

**Smoke test stuck at HTTP 000**
Keycloak is not reachable at the configured URL. Verify the container is running and port 8082 is published:
```bash
docker ps | grep keycloak
curl -sf http://localhost:8082/realms/zero-trust/.well-known/openid-configuration | jq .issuer
```

**CIBA flow initiates but backend never receives `/ciba/request`**
The Keycloak container was not started with the SPI argument. Check `docker-compose.yml` for the `--spi-ciba-auth-channel-...` line in the Keycloak service `command:` block.

**Checking CIBA is correctly configured in Keycloak:**
```bash
curl -sf http://localhost:8082/realms/zero-trust/.well-known/openid-configuration \
  | jq '{ciba_endpoint: .backchannel_authentication_endpoint, modes: .backchannel_token_delivery_modes_supported}'
```
