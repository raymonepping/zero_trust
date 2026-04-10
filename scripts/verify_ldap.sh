#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/verify_ldap.sh

Description:
  Sanity checks to confirm the local LDAP setup is ready and that
  ./scripts/setup_ldap.sh has run successfully.
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

ok() {
  printf 'OK  %s\n' "$*"
}

LDAP_HOST="${LDAP_HOST:-127.0.0.1}"
LDAP_PORT="${LDAP_PORT:-1389}"
LDAP_ADMIN_DN="${LDAP_ADMIN_DN:-cn=admin,dc=my,dc=org}"
LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:-admin}"
LDAP_BASE_DN="${LDAP_BASE_DN:-dc=my,dc=org}"
LDIF_FILE="${LDIF_FILE:-ldap/bootstrap.ldif}"
OPENLDAP_CONTAINER="${OPENLDAP_CONTAINER:-zero_trust_openldap}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
ldif_path="${repo_root}/${LDIF_FILE}"

# ldapadd is only needed by setup_ldap.sh, not for verification
for cmd in docker ldapsearch; do
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
info "LDAP OU structure"
ldapsearch -x \
  -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
  -D "${LDAP_ADMIN_DN}" \
  -w "${LDAP_ADMIN_PASSWORD}" \
  -b "${LDAP_BASE_DN}" \
  '(objectClass=organizationalUnit)' \
  ou

printf '\n'
info "LDAP user check (ou=users)"
user_count=$(ldapsearch -x \
  -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
  -D "${LDAP_ADMIN_DN}" \
  -w "${LDAP_ADMIN_PASSWORD}" \
  -b "ou=users,${LDAP_BASE_DN}" \
  '(objectClass=inetOrgPerson)' \
  uid 2>/dev/null \
  | grep -c '^uid:' || true)

if [[ "${user_count}" -gt 0 ]]; then
  ok "Found ${user_count} user(s) in ou=users"
  ldapsearch -x \
    -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "${LDAP_ADMIN_DN}" \
    -w "${LDAP_ADMIN_PASSWORD}" \
    -b "ou=users,${LDAP_BASE_DN}" \
    '(objectClass=inetOrgPerson)' \
    uid \
    | grep '^uid:'
else
  warn "No users found in ou=users — setup_ldap.sh may not have run"
fi

printf '\n'
info "LDAP group check (ou=groups)"
group_count=$(ldapsearch -x \
  -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
  -D "${LDAP_ADMIN_DN}" \
  -w "${LDAP_ADMIN_PASSWORD}" \
  -b "ou=groups,${LDAP_BASE_DN}" \
  '(objectClass=posixGroup)' \
  cn 2>/dev/null \
  | grep -c '^cn:' || true)

if [[ "${group_count}" -gt 0 ]]; then
  ok "Found ${group_count} group(s) in ou=groups"
  ldapsearch -x \
    -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "${LDAP_ADMIN_DN}" \
    -w "${LDAP_ADMIN_PASSWORD}" \
    -b "ou=groups,${LDAP_BASE_DN}" \
    '(objectClass=posixGroup)' \
    cn memberUid \
    | grep -E '^(cn|memberUid):'
else
  warn "No groups found in ou=groups — setup_ldap.sh may not have run"
fi

printf '\n'
info "OpenLDAP container port mapping"
docker port "${OPENLDAP_CONTAINER}" || warn "Could not read docker port mapping for ${OPENLDAP_CONTAINER}"

printf '\n'
info "Summary"
printf '%s\n' "LDAP admin bind works and ldapsearch is installed."
if [[ "${user_count:-0}" -gt 0 && "${group_count:-0}" -gt 0 ]]; then
  printf '%s\n' "Users and groups are populated — setup_ldap.sh has run."
else
  printf '%s\n' "Users or groups are missing — run ./scripts/setup_ldap.sh"
fi
printf '%s\n' "setup_ldap.sh should be able to run against the current local stack."
