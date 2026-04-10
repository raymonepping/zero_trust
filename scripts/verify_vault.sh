#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/verify_vault.sh

Description:
  Basic sanity checks to confirm the local Vault setup is running, reachable,
  and unsealed. If VAULT_TOKEN is available, also lists enabled secrets engines
  and auth methods.
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

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_CONTAINER="${VAULT_CONTAINER:-zero_trust_vault}"

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
info "Vault host reachability"
curl -sSf -o /dev/null "${VAULT_ADDR}/v1/sys/health"
printf '%s\n' "${VAULT_ADDR}"

printf '\n'
info "Vault health summary"
curl -sSf "${VAULT_ADDR}/v1/sys/health" | jq '{initialized, sealed, standby, version, enterprise, cluster_name}'

sealed_state="$(curl -sSf "${VAULT_ADDR}/v1/sys/health" | jq -r '.sealed')"
if [[ "${sealed_state}" != "false" ]]; then
  warn "Vault is reachable but still sealed."
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
info "Vault token lookup sanity"
vault token lookup >/dev/null
printf '%s\n' "VAULT_TOKEN is valid"

printf '\n'
info "Enabled secrets engines"
vault secrets list

printf '\n'
info "Enabled auth methods"
vault auth list

printf '\n'
info "Summary"
printf '%s\n' "Vault is reachable from the host."
if [[ "${sealed_state}" == "false" ]]; then
  printf '%s\n' "Vault is unsealed."
else
  printf '%s\n' "Vault is still sealed."
fi
printf '%s\n' "Secrets and auth mount listings were printed because VAULT_TOKEN is available."
