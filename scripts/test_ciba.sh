#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# test_ciba.sh — End-to-end CIBA flow test via curl
#
# Prerequisites:
#   - All containers running (with docker-compose.ciba.yml overlay)
#   - setup_ciba.sh and setup_ciba_keycloak.sh completed
#   - Backend has ciba.js, ciba-routes.js, connector patch, server patch
#
# This script tests the full flow:
#   1. Get a user JWT from the backend auth proxy
#   2. Initiate a CIBA request (backend → Keycloak)
#   3. Poll for pending approval (simulating frontend)
#   4. Approve the request (simulating user clicking "Approve")
#   5. Poll CIBA session status until approved
#   6. Execute the write with the CIBA session
#   7. Verify the order was updated
# ---------------------------------------------------------------------------

BACKEND_URL="${BACKEND_URL:-http://localhost:3000}"
USERNAME="${TEST_USERNAME:-repping}"
PASSWORD="${TEST_PASSWORD:-password}"
ORDER_ID="${TEST_ORDER_ID:-1}"
NEW_STATUS="${TEST_NEW_STATUS:-shipped}"

C_GREEN="\033[32m"; C_RED="\033[31m"; C_CYAN="\033[36m"
C_YELLOW="\033[33m"; C_DIM="\033[2m"; C_RESET="\033[0m"

ok()   { echo -e "${C_GREEN}✔${C_RESET} $*"; }
err()  { echo -e "${C_RED}✖ $*${C_RESET}" >&2; }
info() { echo -e "${C_CYAN}→${C_RESET} $*"; }
dim()  { echo -e "${C_DIM}$*${C_RESET}"; }

echo
echo -e "${C_YELLOW}═══════════════════════════════════════════════════${C_RESET}"
echo -e "${C_YELLOW}  CIBA End-to-End Test${C_RESET}"
echo -e "${C_YELLOW}═══════════════════════════════════════════════════${C_RESET}"
echo

# ─── Step 1: Get user JWT ─────────────────────────────────────────────────
info "Step 1: Authenticating as '${USERNAME}'..."

TOKEN_RESPONSE=$(curl -sf "${BACKEND_URL}/auth/token" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\"}")

ACCESS_TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.access_token')

if [ -z "${ACCESS_TOKEN}" ] || [ "${ACCESS_TOKEN}" = "null" ]; then
  err "Failed to get JWT. Response: ${TOKEN_RESPONSE}"
  exit 1
fi

ok "JWT obtained for '${USERNAME}'"
dim "  Token: ${ACCESS_TOKEN:0:50}..."
echo

# ─── Step 2: Initiate CIBA ────────────────────────────────────────────────
info "Step 2: Initiating CIBA flow (order ${ORDER_ID} → ${NEW_STATUS})..."

INITIATE_RESPONSE=$(curl -sf "${BACKEND_URL}/ciba/initiate" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d "{\"orderId\":${ORDER_ID},\"newStatus\":\"${NEW_STATUS}\"}")

SESSION_ID=$(echo "${INITIATE_RESPONSE}" | jq -r '.sessionId')
AUTH_REQ_ID=$(echo "${INITIATE_RESPONSE}" | jq -r '.authReqId')
EXPIRES_IN=$(echo "${INITIATE_RESPONSE}" | jq -r '.expiresIn')

if [ -z "${SESSION_ID}" ] || [ "${SESSION_ID}" = "null" ]; then
  err "CIBA initiate failed. Response: ${INITIATE_RESPONSE}"
  exit 1
fi

ok "CIBA session created"
dim "  Session:    ${SESSION_ID}"
dim "  Auth Req:   ${AUTH_REQ_ID}"
dim "  Expires in: ${EXPIRES_IN}s"
echo

# ─── Step 3: Poll for pending approval ────────────────────────────────────
info "Step 3: Checking for pending approval request..."
sleep 2

PENDING_RESPONSE=$(curl -sf "${BACKEND_URL}/ciba/pending" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}")

PENDING_COUNT=$(echo "${PENDING_RESPONSE}" | jq 'length')

if [ "${PENDING_COUNT}" = "0" ]; then
  err "No pending CIBA requests found. Keycloak may not have delegated."
  echo "  Check: is docker-compose.ciba.yml active?"
  echo "  Check: backend logs for POST /ciba/request from Keycloak"
  dim "  Response: ${PENDING_RESPONSE}"
  exit 1
fi

REQUEST_ID=$(echo "${PENDING_RESPONSE}" | jq -r '.[0].id')
BINDING_MSG=$(echo "${PENDING_RESPONSE}" | jq -r '.[0].bindingMessage')

ok "Pending approval found"
dim "  Request ID: ${REQUEST_ID:0:50}..."
dim "  Action:     ${BINDING_MSG}"
echo

# ─── Step 4: Approve the request ──────────────────────────────────────────
info "Step 4: Approving CIBA request..."

APPROVE_RESPONSE=$(curl -sf "${BACKEND_URL}/ciba/approve" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d "{\"requestId\":\"${REQUEST_ID}\",\"decision\":\"SUCCEED\"}")

APPROVE_STATUS=$(echo "${APPROVE_RESPONSE}" | jq -r '.status')

if [ "${APPROVE_STATUS}" != "callback_sent" ]; then
  err "Approval failed. Response: ${APPROVE_RESPONSE}"
  exit 1
fi

ok "CIBA request approved — callback sent to Keycloak"
echo

# ─── Step 5: Poll session status until approved ───────────────────────────
info "Step 5: Waiting for CIBA session approval..."

for i in $(seq 1 24); do
  sleep 5

  STATUS_RESPONSE=$(curl -sf "${BACKEND_URL}/ciba/status/${SESSION_ID}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}")

  CIBA_STATUS=$(echo "${STATUS_RESPONSE}" | jq -r '.status')

  dim "  Poll ${i}: status=${CIBA_STATUS}"

  if [ "${CIBA_STATUS}" = "approved" ]; then
    ok "CIBA session approved — write authorized"
    break
  fi

  if [ "${CIBA_STATUS}" = "denied" ] || [ "${CIBA_STATUS}" = "expired" ]; then
    err "CIBA session ${CIBA_STATUS}"
    exit 1
  fi
done

if [ "${CIBA_STATUS}" != "approved" ]; then
  err "Timed out waiting for CIBA approval"
  exit 1
fi
echo

# ─── Step 6: Execute the write ────────────────────────────────────────────
info "Step 6: Executing order update via CIBA-gated endpoint..."

WRITE_RESPONSE=$(curl -sf "${BACKEND_URL}/ciba/orders/${ORDER_ID}/status" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d "{\"newStatus\":\"${NEW_STATUS}\",\"cibaSessionId\":\"${SESSION_ID}\"}")

WRITE_SUCCESS=$(echo "${WRITE_RESPONSE}" | jq -r '.success')
WRITE_USER=$(echo "${WRITE_RESPONSE}" | jq -r '.writeUser')
WRITE_STATUS=$(echo "${WRITE_RESPONSE}" | jq -r '.status')

if [ "${WRITE_SUCCESS}" != "true" ]; then
  err "Write failed. Response: ${WRITE_RESPONSE}"
  exit 1
fi

ok "Order ${ORDER_ID} updated to '${WRITE_STATUS}'"
dim "  Write credential: ${WRITE_USER}"
dim "  CIBA session:     ${SESSION_ID}"
echo

# ─── Step 7: Verify ───────────────────────────────────────────────────────
info "Step 7: Verifying order status via read path..."

ORDERS_RESPONSE=$(curl -sf "${BACKEND_URL}/orders" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}")

CURRENT_STATUS=$(echo "${ORDERS_RESPONSE}" | jq -r ".[] | select(.id == ${ORDER_ID}) | .status // empty")
if [ "${CURRENT_STATUS}" != "${NEW_STATUS}" ]; then
  err "Verification failed. Expected order ${ORDER_ID} status '${NEW_STATUS}', got '${CURRENT_STATUS:-<missing>}'"
  exit 1
fi

ok "Verification complete — order ${ORDER_ID} status is '${CURRENT_STATUS}'"
echo

# ─── Summary ──────────────────────────────────────────────────────────────
echo -e "${C_YELLOW}═══════════════════════════════════════════════════${C_RESET}"
echo -e "${C_GREEN}  CIBA flow complete${C_RESET}"
echo
echo -e "  User:           ${USERNAME}"
echo -e "  Action:         Update order ${ORDER_ID} → ${NEW_STATUS}"
echo -e "  CIBA session:   ${SESSION_ID}"
echo -e "  Auth req ID:    ${AUTH_REQ_ID}"
echo -e "  Write user:     ${WRITE_USER}"
echo -e "  Status:         executed"
echo
echo -e "  ${C_DIM}The agent requested elevated access.${C_RESET}"
echo -e "  ${C_DIM}The user explicitly approved the specific action.${C_RESET}"
echo -e "  ${C_DIM}A write-scoped credential was issued and immediately revoked.${C_RESET}"
echo -e "  ${C_DIM}The full chain is in the Vault audit log.${C_RESET}"
echo -e "${C_YELLOW}═══════════════════════════════════════════════════${C_RESET}"
echo
