#!/usr/bin/env bash
set -euo pipefail

LDAP_HOST="${LDAP_HOST:-localhost}"
LDAP_PORT="${LDAP_PORT:-1389}"
LDAP_ADMIN_DN="${LDAP_ADMIN_DN:-cn=admin,dc=my,dc=org}"
LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:-admin}"
LDAP_BASE_DN="${LDAP_BASE_DN:-dc=my,dc=org}"

LDIF_FILE="${LDIF_FILE:-ldap/bootstrap.ldif}"

log() {
  echo
  echo "[LDAP] $1"
}

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null || fail "Missing command: $1"
}

ldap_ok() {
  ldapsearch -x -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "$LDAP_ADMIN_DN" \
    -w "$LDAP_ADMIN_PASSWORD" \
    -b "$LDAP_BASE_DN" >/dev/null 2>&1
}

entry_exists() {
  local dn="$1"
  ldapsearch -x -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "$LDAP_ADMIN_DN" \
    -w "$LDAP_ADMIN_PASSWORD" \
    -b "$dn" >/dev/null 2>&1
}

setup() {
  require_cmd ldapadd
  require_cmd ldapsearch

  log "Checking LDAP connectivity"
  ldap_ok || fail "Cannot connect to LDAP"

  log "Processing LDIF: $LDIF_FILE"

  # Split LDIF into entries and apply one by one
  awk 'BEGIN { RS=""; FS="\n" } { print > ("ldap_entry_" NR ".ldif") }' "$LDIF_FILE"

  for f in ldap_entry_*.ldif; do
    dn=$(grep '^dn:' "$f" | head -1 | cut -d' ' -f2-)

    if entry_exists "$dn"; then
      log "Skipping existing entry: $dn"
    else
      log "Adding entry: $dn"
      ldapadd -x -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
        -D "$LDAP_ADMIN_DN" \
        -w "$LDAP_ADMIN_PASSWORD" \
        -f "$f"
    fi

    rm "$f"
  done

  log "LDAP setup complete"
}

setup