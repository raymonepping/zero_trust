#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/verify_vault.sh

Description:
  Basic sanity checks to confirm the local Vault setup is running, reachable,
  and unsealed. If VAULT_TOKEN is available, also lists enabled secrets engines
  and auth methods, and verifies workshop-specific mounts are present.
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

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_CONTAINER="${VAULT_CONTAINER:-zero_trust_vault}"
VAULT_AGENT_CONTAINER="${VAULT_AGENT_CONTAINER:-zero_trust_vault_agent}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

for cmd in docker curl jq; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    error "Required command not found: ${cmd}"
    exit 1
  }
done

printf '\n'
info "Vault container status"
printf '%s %s\n' "${VAULT_CONTAINER}" "$(container_status "${VAULT_CONTAINER}")"

printf '\n'
info "Vault Agent container status"
printf '%s %s\n' "${VAULT_AGENT_CONTAINER}" "$(container_status "${VAULT_AGENT_CONTAINER}")"

# /v1/sys/health returns 503 when sealed and 501 when uninitialised — do NOT
# use curl -f here, it would exit non-zero before we can report anything useful.
printf '\n'
info "Vault host reachability"
health_json=$(curl -s "${VAULT_ADDR}/v1/sys/health" 2>/dev/null || true)
if [[ -z "${health_json}" ]]; then
  error "Vault is not reachable at ${VAULT_ADDR} (connection refused or timeout)"
  exit 1
fi
ok "${VAULT_ADDR}"

printf '\n'
info "Vault health summary"
echo "${health_json}" | jq '{initialized, sealed, standby, version, enterprise, cluster_name}'

sealed_state="$(echo "${health_json}" | jq -r '.sealed')"
if [[ "${sealed_state}" != "false" ]]; then
  warn "Vault is reachable but still sealed — run ./scripts/unseal_vault.sh"
fi

if ! command -v vault >/dev/null 2>&1; then
  printf '\n'
  warn "vault CLI not found on PATH. Skipping secrets and auth mount listing."
  exit 0
fi

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  printf '\n'
  warn "VAULT_TOKEN not set. Skipping enabled secrets engine and auth mount listing."
  exit 0
fi

printf '\n'
info "Vault token details"
vault token lookup | grep -E '^\s*(display_name|policies|ttl|expire_time|meta)'

printf '\n'
info "Enabled secrets engines"
vault secrets list

printf '\n'
info "Workshop mount check"
for mount in secret/ database/ sys/; do
  if vault secrets list | grep -q "^${mount}"; then
    ok "${mount}"
  else
    warn "${mount} not found — setup_vault.sh may not have run"
  fi
done

printf '\n'
info "Enabled auth methods"
vault auth list

printf '\n'
info "Workshop auth method check"
for method in approle/ jwt/ ldap/; do
  if vault auth list | grep -q "^${method}"; then
    ok "${method}"
  else
    warn "${method} not found — setup_vault.sh may not have run"
  fi
done

printf '\n'
info "Vault Agent rendered credentials"
docker exec "${VAULT_AGENT_CONTAINER}" sh -c \
  'test -f /vault/secrets/db-creds.json && echo "db-creds.json present" || echo "db-creds.json missing"'

printf '\n'
info "Summary"
if [[ "${sealed_state}" == "false" ]]; then
  printf '%s\n' "Vault is reachable and unsealed."
else
  printf '%s\n' "Vault is reachable but sealed."
fi
