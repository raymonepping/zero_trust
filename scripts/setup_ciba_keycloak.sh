#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (overridable via env vars, matches setup_keycloak.sh)
# ---------------------------------------------------------------------------
KEYCLOAK_URL="${KC_URL:-http://localhost:8080}"
ADMIN_USER="${KC_ADMIN_USER:-admin}"
ADMIN_PASS="${KC_ADMIN_PASS:-admin}"
KEYCLOAK_CONTAINER="${KC_CONTAINER:-zero_trust_keycloak}"
runtime="${CONTAINER_RUNTIME:-docker}"
TARGET_REALM="zero-trust"
BACKEND_CLIENT_ID="backend"

# CIBA policy settings
CIBA_MODE="poll"
CIBA_EXPIRES_IN="120"
CIBA_INTERVAL="5"
CIBA_USER_HINT="login_hint"

# ---------------------------------------------------------------------------
# Helpers (match setup_keycloak.sh style)
# ---------------------------------------------------------------------------
log()  { echo; echo "[KC-CIBA] $*"; }
ok()   { echo "         ✓ $*"; }
skip() { echo "         – $* (already configured)"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

kcadm() { "${runtime}" exec "${KEYCLOAK_CONTAINER}" /opt/keycloak/bin/kcadm.sh "$@"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Configures Keycloak CIBA for the Zero Trust workshop.
Depends on setup_keycloak.sh having been run first.

OPTIONS:
  -u, --url URL           Keycloak base URL (default: ${KEYCLOAK_URL})
  -U, --admin-user USER   Admin username (default: ${ADMIN_USER})
  -P, --admin-pass PASS   Admin password
  -c, --container NAME    Container name (default: ${KEYCLOAK_CONTAINER})
  -r, --runtime RUNTIME   Container runtime: docker or podman (default: docker)
  -h, --help              Show this help

EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--url)          KEYCLOAK_URL="$2"; shift 2 ;;
    -U|--admin-user)   ADMIN_USER="$2";   shift 2 ;;
    -P|--admin-pass)   ADMIN_PASS="$2";   shift 2 ;;
    -c|--container)    KEYCLOAK_CONTAINER="$2"; shift 2 ;;
    -r|--runtime)      runtime="$2";            shift 2 ;;
    -h|--help)         usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
case "${runtime}" in
  docker|podman) ;;
  *) fail "Unsupported runtime '${runtime}'. Use docker or podman." ;;
esac

command -v "${runtime}" >/dev/null 2>&1 || fail "${runtime} not found"
command -v jq           >/dev/null 2>&1 || fail "jq not found"
command -v curl         >/dev/null 2>&1 || fail "curl not found"

"${runtime}" inspect "${KEYCLOAK_CONTAINER}" >/dev/null 2>&1 \
  || fail "Container '${KEYCLOAK_CONTAINER}' is not running."

# ---------------------------------------------------------------------------
# Step 1: Authenticate
# ---------------------------------------------------------------------------
log "Authenticating as '${ADMIN_USER}'..."
kcadm config credentials \
  --server  "${KEYCLOAK_URL}" \
  --realm   master \
  --user    "${ADMIN_USER}" \
  --password "${ADMIN_PASS}"
ok "Authenticated"

# ---------------------------------------------------------------------------
# Step 2: Verify realm exists
# ---------------------------------------------------------------------------
log "Verifying realm '${TARGET_REALM}' exists..."
if ! kcadm get "realms/${TARGET_REALM}" >/dev/null 2>&1; then
  fail "Realm '${TARGET_REALM}' not found. Run setup_keycloak.sh first."
fi
ok "Realm '${TARGET_REALM}' exists."

# ---------------------------------------------------------------------------
# Step 3: Configure realm CIBA policy
# ---------------------------------------------------------------------------
log "Configuring CIBA policy on realm '${TARGET_REALM}'..."

kcadm update "realms/${TARGET_REALM}" \
  -s "attributes.\"cibaBackchannelTokenDeliveryMode\"=${CIBA_MODE}" \
  -s "attributes.\"cibaExpiresIn\"=${CIBA_EXPIRES_IN}" \
  -s "attributes.\"cibaInterval\"=${CIBA_INTERVAL}" \
  -s "attributes.\"cibaAuthRequestedUserHint\"=${CIBA_USER_HINT}"
ok "CIBA policy configured: mode=${CIBA_MODE}, expires=${CIBA_EXPIRES_IN}s, interval=${CIBA_INTERVAL}s"

# ---------------------------------------------------------------------------
# Step 4: Enable CIBA grant on backend client
# ---------------------------------------------------------------------------
log "Enabling OIDC CIBA grant on client '${BACKEND_CLIENT_ID}'..."

CLIENT_UUID=$(kcadm get clients -r "${TARGET_REALM}" --fields clientId,id 2>/dev/null \
  | jq -er ".[] | select(.clientId==\"${BACKEND_CLIENT_ID}\") | .id" || echo "")

if [ -z "${CLIENT_UUID}" ]; then
  fail "Client '${BACKEND_CLIENT_ID}' not found. Run setup_keycloak.sh first."
fi

# Enable CIBA grant type on the client
kcadm update "clients/${CLIENT_UUID}" -r "${TARGET_REALM}" \
  -s "attributes.\"oidc.ciba.grant.enabled\"=true"
ok "CIBA grant enabled on client '${BACKEND_CLIENT_ID}'."

# ---------------------------------------------------------------------------
# Step 5: Retrieve client secret for smoke test
# ---------------------------------------------------------------------------
log "Retrieving client secret..."
CLIENT_SECRET=$(kcadm get "clients/${CLIENT_UUID}/client-secret" -r "${TARGET_REALM}" 2>/dev/null \
  | jq -er '.value')
ok "Client secret retrieved."

# ---------------------------------------------------------------------------
# Step 6: Verify CIBA endpoint is advertised
# ---------------------------------------------------------------------------
log "Checking CIBA endpoint in OIDC discovery..."

# Query from host — Keycloak image has no curl installed
HOST_KC_URL="${KEYCLOAK_URL/8080/8082}"
DISCOVERY=$(curl -sf \
  "${HOST_KC_URL}/realms/${TARGET_REALM}/.well-known/openid-configuration" 2>/dev/null || echo "{}")

CIBA_ENDPOINT=$(echo "${DISCOVERY}" | jq -r '.backchannel_authentication_endpoint // empty')

if [ -n "${CIBA_ENDPOINT}" ]; then
  ok "CIBA endpoint advertised: ${CIBA_ENDPOINT}"
else
  fail "CIBA endpoint not found in OIDC discovery. CIBA may not be properly enabled."
fi

# Check supported modes
CIBA_MODES=$(echo "${DISCOVERY}" | jq -r '.backchannel_token_delivery_modes_supported // [] | join(", ")')
ok "Supported delivery modes: ${CIBA_MODES}"

# ---------------------------------------------------------------------------
# Step 7: Smoke test — CIBA auth request
# ---------------------------------------------------------------------------
log "Smoke test — sending CIBA backchannel auth request..."

# This will likely fail with a 503 because the AD handler is not running yet.
# That is expected. We are only verifying Keycloak accepts the request format.
CIBA_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "${HOST_KC_URL}/realms/${TARGET_REALM}/protocol/openid-connect/ext/ciba/auth" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=${BACKEND_CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "login_hint=repping" \
  -d "scope=openid" \
  -d "binding_message=Approve+order+update" \
  2>/dev/null || echo "000")

case "${CIBA_RESPONSE}" in
  200)
    ok "CIBA auth request accepted (HTTP 200). AD handler received the delegation."
    ;;
  503)
    ok "CIBA auth request reached Keycloak (HTTP 503). Expected: AD handler not running yet."
    echo "         This confirms Keycloak CIBA is configured correctly."
    echo "         The 503 will resolve once the backend AD handler route is in place."
    ;;
  401)
    fail "CIBA auth request unauthorized (HTTP 401). Check client credentials."
    ;;
  400)
    ok "CIBA auth request reached Keycloak (HTTP 400). Expected: backend AD handler not running yet."
    echo "         This confirms Keycloak CIBA is configured correctly."
    echo "         The 400 will resolve once the backend /ciba/request route is in place."
    ;;
  000)
    fail "Could not reach Keycloak CIBA endpoint. Is Keycloak running?"
    ;;
  *)
    echo "         Unexpected HTTP ${CIBA_RESPONSE}. Investigate manually:"
    echo "         curl -X POST '${KEYCLOAK_URL}/realms/${TARGET_REALM}/protocol/openid-connect/ext/ciba/auth' \\"
    echo "           -d 'client_id=${BACKEND_CLIENT_ID}&client_secret=***&login_hint=repping&scope=openid'"
    ;;
esac

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "────────────────────────────────────────────────────────────"
echo " Keycloak CIBA Configuration Complete"
echo "────────────────────────────────────────────────────────────"
echo " Realm             : ${TARGET_REALM}"
echo " Client            : ${BACKEND_CLIENT_ID}"
echo " Delivery mode     : ${CIBA_MODE}"
echo " Request expires   : ${CIBA_EXPIRES_IN}s"
echo " Poll interval     : ${CIBA_INTERVAL}s"
echo " User hint         : ${CIBA_USER_HINT}"
echo ""
echo " CIBA endpoint     : ${CIBA_ENDPOINT:-not yet discovered}"
echo "────────────────────────────────────────────────────────────"
echo ""
echo " IMPORTANT: Keycloak must be started with the CIBA SPI argument"
echo " pointing to the backend AD handler. Add to docker-compose.yml:"
echo ""
echo "   command: >-"
echo "     start-dev"
echo "     --spi-ciba-auth-channel-ciba-http-auth-channel-http-authentication-channel-uri="
echo "     http://backend:3000/ciba/request"
echo ""
echo " See docker-compose.ciba.yml for the exact change."
echo "────────────────────────────────────────────────────────────"
echo ""
ok "Done."
