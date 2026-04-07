#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3000}"
KC_USERNAME="${KC_USERNAME:-repping}"
KC_PASSWORD="${KC_PASSWORD:-password}"
QUESTION="${QUESTION:-What can you tell me about Cojan?}"
SELECTED_ROUTES=()
REFRESH_TOKEN_ONLY=false
CLEANUP_LEASES=false
LEASE_ROLES=(viewer-read support-read admin-read)

for cmd in curl jq; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: '${cmd}' is required but not installed." >&2
    exit 1
  fi
done

AUTH_HEADER=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Tests the backend routes exposed by the Zero Trust workshop API.
By default, the script runs the full route test sequence, including:
  - public GET routes
  - token acquisition via /auth/token
  - authenticated route checks
  - lease rotation test

OPTIONS:
  -b, --base-url URL       Base URL for the backend API
  -u, --username USER      Keycloak username for /auth/token
  -p, --password PASS      Keycloak password for /auth/token
  -t, --refresh-token      Fetch and print a fresh token, then exit
  -c, --cleanup            Revoke outstanding dynamic DB leases in Vault, then exit
  -r, --route NAME         Test only a specific route group or route alias.
                           Repeat to test multiple items.
  -l, --list-routes        List supported route selectors and exit
  -h, --help               Show this help

Supported route selectors:
  root
  health
  users
  orders
  preferences
  credentials
  health-lease
  rotate
  auth-token
  public
  authenticated
  all

Examples:
  $(basename "$0")
  $(basename "$0") --refresh-token --username repping --password password
  $(basename "$0") --cleanup
  $(basename "$0") --route health
  $(basename "$0") --route auth-token --route users
  $(basename "$0") --username repping --password password --route credentials
  $(basename "$0") --base-url http://localhost:3000 --username repping --password password

Environment overrides:
  BASE_URL
  KC_USERNAME
  KC_PASSWORD
EOF
}

list_routes() {
  cat <<'EOF'
root
health
users
orders
preferences
credentials
health-lease
rotate
auth-token
public
authenticated
all
EOF
}

print_header() {
  echo
  echo "==> $1"
}

show_response() {
  local response="$1"
  local body
  local status
  body="$(printf '%s' "${response}" | sed '$d')"
  status="$(printf '%s' "${response}" | tail -n1)"
  echo "HTTP ${status}"
  if printf '%s' "${body}" | jq . >/dev/null 2>&1; then
    printf '%s' "${body}" | jq .
  else
    printf '%s\n' "${body}"
  fi
}

run_get() {
  local path="$1"
  local label="$2"
  print_header "${label}"
  local response
  response="$(curl -sS -w '\n%{http_code}' "${AUTH_HEADER[@]}" "${BASE_URL}${path}")"
  show_response "${response}"
}

run_post_json() {
  local path="$1"
  local label="$2"
  local payload="$3"
  print_header "${label}"
  local response
  response="$(curl -sS -w '\n%{http_code}' "${AUTH_HEADER[@]}" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${BASE_URL}${path}")"
  show_response "${response}"
}

run_auth_token() {
  run_post_json "/auth/token" "POST /auth/token" \
    "{\"username\":\"${KC_USERNAME}\",\"password\":\"${KC_PASSWORD}\"}"
}

refresh_token_only() {
  print_header "Refreshing Token"
  run_auth_token
}

cleanup_leases() {
  if ! command -v vault >/dev/null 2>&1; then
    echo "ERROR: 'vault' is required for --cleanup." >&2
    exit 1
  fi

  print_header "Cleaning Up Vault DB Leases"

  local role
  for role in "${LEASE_ROLES[@]}"; do
    echo "Role: ${role}"

    local lease_ids
    lease_ids="$(vault list -format=json "sys/leases/lookup/database/creds/${role}" 2>/dev/null | jq -r '.[]?' || true)"

    if [ -z "${lease_ids}" ]; then
      echo "  no outstanding leases found"
      continue
    fi

    local lease_id
    while IFS= read -r lease_id; do
      [ -z "${lease_id}" ] && continue
      vault write sys/leases/revoke "lease_id=database/creds/${role}/${lease_id}" >/dev/null
      echo "  revoked: database/creds/${role}/${lease_id}"
    done <<< "${lease_ids}"
  done
}

fetch_token() {
  TOKEN="$(
    curl -sS \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"${KC_USERNAME}\",\"password\":\"${KC_PASSWORD}\"}" \
      "${BASE_URL}/auth/token" | jq -r '.access_token // empty'
  )"

  if [ -z "${TOKEN}" ]; then
    echo "ERROR: failed to obtain access token from ${BASE_URL}/auth/token" >&2
    exit 1
  fi

  AUTH_HEADER=(-H "Authorization: Bearer ${TOKEN}")
}

run_public_routes() {
  run_get "/" "GET /"
  run_get "/health" "GET /health"
  run_get "/users" "GET /users (unauthenticated)"
  run_get "/orders" "GET /orders (unauthenticated)"
  run_get "/preferences" "GET /preferences (unauthenticated)"
  run_get "/credentials" "GET /credentials (unauthenticated)"
  run_get "/health/lease" "GET /health/lease"
}

run_authenticated_routes() {
  fetch_token
  run_get "/users" "GET /users (authenticated)"
  run_get "/orders" "GET /orders (authenticated)"
  run_get "/preferences" "GET /preferences (authenticated)"
  run_get "/credentials" "GET /credentials (authenticated)"
  run_get "/health/lease" "GET /health/lease (after token acquisition)"
  run_post_json "/health/lease/rotate" "POST /health/lease/rotate" '{}'
}

run_selector() {
  local selector="$1"
  case "${selector}" in
    root) run_get "/" "GET /" ;;
    health) run_get "/health" "GET /health" ;;
    users) fetch_token; run_get "/users" "GET /users (authenticated)" ;;
    orders) fetch_token; run_get "/orders" "GET /orders (authenticated)" ;;
    preferences) fetch_token; run_get "/preferences" "GET /preferences (authenticated)" ;;
    credentials) fetch_token; run_get "/credentials" "GET /credentials (authenticated)" ;;
    health-lease) run_get "/health/lease" "GET /health/lease" ;;
    rotate) fetch_token; run_post_json "/health/lease/rotate" "POST /health/lease/rotate" '{}' ;;
    auth-token) run_auth_token ;;
    public) run_public_routes ;;
    authenticated) run_authenticated_routes ;;
    all) run_public_routes; run_auth_token; run_authenticated_routes ;;
    *)
      echo "ERROR: unknown route selector '${selector}'" >&2
      echo "Run with --list-routes to see supported values." >&2
      exit 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--base-url)
      BASE_URL="$2"
      shift 2
      ;;
    -u|--username)
      KC_USERNAME="$2"
      shift 2
      ;;
    -p|--password)
      KC_PASSWORD="$2"
      shift 2
      ;;
    -t|--refresh-token)
      REFRESH_TOKEN_ONLY=true
      shift
      ;;
    -c|--cleanup)
      CLEANUP_LEASES=true
      shift
      ;;
    -r|--route)
      SELECTED_ROUTES+=("$2")
      shift 2
      ;;
    -l|--list-routes)
      list_routes
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option '$1'" >&2
      echo
      usage >&2
      exit 1
      ;;
  esac
done

print_header "Route List"
cat <<'EOF'
GET  /
GET  /health
GET  /users
GET  /orders
GET  /preferences
GET  /credentials
GET  /health/lease
POST /health/lease/rotate
POST /auth/token
EOF

if [ "${REFRESH_TOKEN_ONLY}" = true ]; then
  refresh_token_only
elif [ "${CLEANUP_LEASES}" = true ]; then
  cleanup_leases
elif [ "${#SELECTED_ROUTES[@]}" -eq 0 ]; then
  run_selector "all"
else
  for selector in "${SELECTED_ROUTES[@]}"; do
    run_selector "${selector}"
  done
fi
