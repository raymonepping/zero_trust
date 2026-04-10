#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/verify_ldap.sh

Description:
  Basic sanity checks to confirm the local LDAP setup is ready for
  ./scripts/setup_ldap.sh.
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

LDAP_HOST="${LDAP_HOST:-127.0.0.1}"
LDAP_PORT="${LDAP_PORT:-1389}"
LDAP_ADMIN_DN="${LDAP_ADMIN_DN:-cn=admin,dc=my,dc=org}"
LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:-admin}"
LDAP_BASE_DN="${LDAP_BASE_DN:-dc=my,dc=org}"
LDIF_FILE="${LDIF_FILE:-ldap/bootstrap.ldif}"
OPENLDAP_CONTAINER="${LDAP_CONTAINER:-zero_trust_openldap}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
ldif_path="${repo_root}/${LDIF_FILE}"

for cmd in docker ldapsearch ldapadd; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    error "Required command not found: ${cmd}"
    exit 1
  }
done

if [[ ! -f "${ldif_path}" ]]; then
  error "LDIF file not found: ${ldif_path}"
  exit 1
fi

printf '\n'
info "LDAP bootstrap file"
printf '%s\n' "${ldif_path}"

printf '\n'
info "OpenLDAP container status"
docker inspect "${OPENLDAP_CONTAINER}" --format '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}'

printf '\n'
info "LDAP host bind test"
ldapsearch -x \
  -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
  -D "${LDAP_ADMIN_DN}" \
  -w "${LDAP_ADMIN_PASSWORD}" \
  -b "${LDAP_BASE_DN}" \
  -s base \
  dn

printf '\n'
info "LDAP expected branch check"
ldapsearch -x \
  -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
  -D "${LDAP_ADMIN_DN}" \
  -w "${LDAP_ADMIN_PASSWORD}" \
  -b "${LDAP_BASE_DN}" \
  '(objectClass=organizationalUnit)' \
  ou

printf '\n'
info "OpenLDAP container port mapping"
docker port "${OPENLDAP_CONTAINER}" || warn "Could not read docker port mapping for ${OPENLDAP_CONTAINER}"

printf '\n'
info "Summary"
printf '%s\n' "LDAP admin bind works and ldapadd/ldapsearch are installed."
printf '%s\n' "setup_ldap.sh should be able to run with the current host-side defaults."
