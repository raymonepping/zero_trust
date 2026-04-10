#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/verify_keycloak.sh

Description:
  Basic sanity checks to confirm the local Keycloak setup is ready for
  ./scripts/setup_keycloak.sh.
EOF
}

info() {
  printf '==> %s\n' "$*"
}

error() {
  printf 'ERR %s\n' "$*" >&2
}

warn() {
  printf 'WARN %s\n' "$*" >&2
}

container_status() {
  local container_name="$1"
  local status health

  status="$(docker inspect "${container_name}" --format '{{.State.Status}}')"
  health="$(docker inspect "${container_name}" --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}')"

  if [[ -n "${health}" ]]; then
    printf '%s %s\n' "${status}" "${health}"
  else
    printf '%s\n' "${status}"
  fi
}

KEYCLOAK_URL="${KC_URL:-http://localhost:8082}"
ADMIN_USER="${KC_ADMIN_USER:-admin}"
ADMIN_PASS="${KC_ADMIN_PASS:-admin}"
KEYCLOAK_CONTAINER="${KC_CONTAINER:-zero_trust_keycloak}"
OPENLDAP_CONTAINER="${LDAP_CONTAINER:-zero_trust_openldap}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

for cmd in docker jq curl; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    error "Required command not found: ${cmd}"
    exit 1
  }
done

printf '\n'
info "Keycloak container status"
printf '%s %s\n' "${KEYCLOAK_CONTAINER}" "$(container_status "${KEYCLOAK_CONTAINER}")"

printf '\n'
info "OpenLDAP dependency container status"
printf '%s %s\n' "${OPENLDAP_CONTAINER}" "$(container_status "${OPENLDAP_CONTAINER}")"

printf '\n'
info "Keycloak host reachability"
curl -sSf -o /dev/null "${KEYCLOAK_URL}"
printf '%s\n' "${KEYCLOAK_URL}"

printf '\n'
info "Keycloak master realm metadata"
curl -sSf "${KEYCLOAK_URL}/realms/master/.well-known/openid-configuration" | jq '{issuer, authorization_endpoint, token_endpoint}'

printf '\n'
info "kcadm availability inside container"
docker exec "${KEYCLOAK_CONTAINER}" test -x /opt/keycloak/bin/kcadm.sh
printf '%s\n' "/opt/keycloak/bin/kcadm.sh"

printf '\n'
info "Keycloak admin login sanity"
docker exec "${KEYCLOAK_CONTAINER}" /opt/keycloak/bin/kcadm.sh config credentials \
  --server "http://localhost:8080" \
  --realm master \
  --user "${ADMIN_USER}" \
  --password "${ADMIN_PASS}" >/dev/null 2>&1
printf '%s\n' "Authenticated with bootstrap admin credentials"

printf '\n'
info "Summary"
printf '%s\n' "Keycloak is reachable, kcadm.sh is present, and admin credentials work."
printf '%s\n' "setup_keycloak.sh should be able to run against the current local stack."
