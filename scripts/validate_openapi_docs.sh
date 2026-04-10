#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OPENAPI_FILE="${ROOT_DIR}/backend/openapi.json"
ROUTES_DOC="${ROOT_DIR}/docs/readme_routes.md"
BACKEND_DOC="${ROOT_DIR}/docs/readme_backend.md"

for cmd in jq grep; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: '${cmd}' is required but not installed." >&2
    exit 1
  fi
done

declare -a DOC_ROUTES=(
  "GET /"
  "GET /health"
  "GET /credentials"
  "GET /health/lease"
  "POST /health/lease/rotate"
  "GET /users"
  "GET /orders"
  "GET /preferences"
  "GET /training"
  "GET /tickets"
  "GET /projects"
  "POST /ask"
  "POST /auth/token"
  "GET /openapi.json"
  "GET /docs"
  "POST /ciba/request"
  "POST /ciba/initiate"
  "GET /ciba/pending"
  "POST /ciba/approve"
  "GET /ciba/status/:sessionId"
  "GET /ciba/diagnostics"
  "POST /orders/:id/status"
)

declare -a OPENAPI_ROUTES=(
  "/"
  "/health"
  "/credentials"
  "/health/lease"
  "/health/lease/rotate"
  "/users"
  "/orders"
  "/preferences"
  "/training"
  "/tickets"
  "/projects"
  "/ask"
  "/auth/token"
  "/openapi.json"
  "/docs"
  "/ciba/request"
  "/ciba/initiate"
  "/ciba/pending"
  "/ciba/approve"
  "/ciba/status/{sessionId}"
  "/ciba/diagnostics"
  "/orders/{id}/status"
)

if [ "${#DOC_ROUTES[@]}" -ne "${#OPENAPI_ROUTES[@]}" ]; then
  echo "ERROR: route lists are out of sync inside this validator." >&2
  exit 1
fi

echo "==> Validating OpenAPI JSON"
jq . "${OPENAPI_FILE}" >/dev/null
echo "OK: ${OPENAPI_FILE} parses as valid JSON"

echo
echo "==> Validating route coverage across docs and spec"

for i in "${!DOC_ROUTES[@]}"; do
  doc_route="${DOC_ROUTES[$i]}"
  openapi_route="${OPENAPI_ROUTES[$i]}"

  if ! grep -Fq "${doc_route}" "${ROUTES_DOC}"; then
    echo "ERROR: missing in ${ROUTES_DOC}: ${doc_route}" >&2
    exit 1
  fi

  if ! grep -Fq "${doc_route}" "${BACKEND_DOC}"; then
    echo "ERROR: missing in ${BACKEND_DOC}: ${doc_route}" >&2
    exit 1
  fi

  if ! jq -e --arg path "${openapi_route}" '.paths[$path]' "${OPENAPI_FILE}" >/dev/null; then
    echo "ERROR: missing in ${OPENAPI_FILE}: ${openapi_route}" >&2
    exit 1
  fi

  echo "OK: ${doc_route}"
done

echo
echo "Validation passed."
