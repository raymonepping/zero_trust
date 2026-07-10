#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
BOUNDARY_ADDR="${BOUNDARY_ADDR:-http://localhost:9200}"
BOUNDARY_AUTH_METHOD_ID="${BOUNDARY_AUTH_METHOD_ID:-ampw_8RfTaBwDa2}"
BOUNDARY_VAULT_CRED_STORE="${BOUNDARY_VAULT_CRED_STORE:-csvlt_s1WV97fBZS}"
BOUNDARY_DB_CONTAINER="${BOUNDARY_DB_CONTAINER:-zero_trust_boundary_db}"
BOUNDARY_CONTROLLER_CONTAINER="${BOUNDARY_CONTROLLER_CONTAINER:-zero_trust_boundary_controller}"
BOUNDARY_ADMIN_LOGIN="${BOUNDARY_ADMIN_LOGIN:-admin}"
BOUNDARY_PASSWORD="${BOUNDARY_PASSWORD:-Password123!}"
BOUNDARY_POLICY_FILE="${BOUNDARY_POLICY_FILE:-${REPO_ROOT}/vault/policies/boundary-vault-full-policy.hcl}"
BOUNDARY_POLICY_NAME="${BOUNDARY_POLICY_NAME:-boundary-controller}"
BOUNDARY_PERIOD="${BOUNDARY_PERIOD:-720h}"
BOUNDARY_NEW_PASSWORD="${BOUNDARY_NEW_PASSWORD:-admin}"
BOUNDARY_RECOVERY_KEY="${BOUNDARY_RECOVERY_KEY:-}"

C_RESET=$'\033[0m'
C_GREEN=$'\033[0;32m'
C_BLUE=$'\033[0;34m'
C_RED=$'\033[0;31m'

log() { printf '%s==> %s%s\n' "$C_BLUE" "$1" "$C_RESET"; }
ok() { printf '%s✓ %s%s\n' "$C_GREEN" "$1" "$C_RESET"; }
err() { printf '%s%s%s\n' "$C_RED" "$1" "$C_RESET" >&2; }
die() { err "$1"; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  sync-vault-token     Apply the Boundary Vault policy, mint a new token, update the Boundary Vault credential store
  reset-admin          Reset the Boundary admin password using the recovery KMS key

Environment overrides:
  VAULT_ADDR, VAULT_TOKEN, BOUNDARY_ADDR, BOUNDARY_PASSWORD
  BOUNDARY_VAULT_CRED_STORE, BOUNDARY_POLICY_FILE, BOUNDARY_POLICY_NAME
  BOUNDARY_DB_CONTAINER, BOUNDARY_CONTROLLER_CONTAINER
  BOUNDARY_ADMIN_LOGIN, BOUNDARY_NEW_PASSWORD, BOUNDARY_RECOVERY_KEY
EOF
}

require_cmds() {
  local missing=0
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || { err "Missing command: $cmd"; missing=1; }
  done
  [[ "$missing" -eq 0 ]] || exit 1
}

require_vault_token() {
  [[ -n "${VAULT_TOKEN:-}" && "${VAULT_TOKEN}" != hvs.REPLACE_WITH_YOUR_TOKEN ]] || die "Set VAULT_TOKEN before running this command"
}

require_boundary_auth() {
  if boundary scopes list >/dev/null 2>&1; then
    ok "Already authenticated to Boundary"
    return 0
  fi

  local pass_file
  pass_file="$(mktemp)"
  trap 'rm -f "$pass_file"' RETURN
  printf '%s\n' "$BOUNDARY_PASSWORD" >"$pass_file"
  boundary authenticate password \
    -auth-method-id="$BOUNDARY_AUTH_METHOD_ID" \
    -login-name="$BOUNDARY_ADMIN_LOGIN" \
    -password="file://${pass_file}" >/dev/null
  ok "Authenticated to Boundary"
}

load_recovery_key() {
  if [[ -n "$BOUNDARY_RECOVERY_KEY" ]]; then
    return 0
  fi
  if [[ -f "${REPO_ROOT}/.env" ]]; then
    BOUNDARY_RECOVERY_KEY="$(awk -F= '$1=="BOUNDARY_RECOVERY_KEY"{print $2}' "${REPO_ROOT}/.env" | tail -1)"
  fi
  [[ -n "$BOUNDARY_RECOVERY_KEY" ]] || die "Set BOUNDARY_RECOVERY_KEY or add it to ${REPO_ROOT}/.env"
}

sync_vault_token() {
  require_cmds vault boundary jq
  require_vault_token
  require_boundary_auth
  [[ -f "$BOUNDARY_POLICY_FILE" ]] || die "Policy file not found: $BOUNDARY_POLICY_FILE"

  log "Applying Vault policy ${BOUNDARY_POLICY_NAME}"
  vault policy write "$BOUNDARY_POLICY_NAME" "$BOUNDARY_POLICY_FILE" >/dev/null
  ok "Vault policy updated from ${BOUNDARY_POLICY_FILE}"

  log "Creating orphan periodic token for Boundary"
  local boundary_token
  boundary_token="$(vault token create -orphan -period="$BOUNDARY_PERIOD" -policy="$BOUNDARY_POLICY_NAME" -format=json | jq -r '.auth.client_token')"
  [[ -n "$boundary_token" && "$boundary_token" != null ]] || die "Failed to create Boundary Vault token"
  ok "Created new Vault token for Boundary"

  log "Updating Boundary Vault credential store ${BOUNDARY_VAULT_CRED_STORE}"
  boundary credential-stores update vault \
    -id="$BOUNDARY_VAULT_CRED_STORE" \
    -vault-token="$boundary_token" \
    -vault-address=http://vault:8200 >/dev/null
  ok "Boundary Vault credential store updated"
  printf 'Token period: %s\n' "$BOUNDARY_PERIOD"
}

reset_admin() {
  require_cmds podman
  load_recovery_key

  log "Fetching Boundary password account ID for ${BOUNDARY_ADMIN_LOGIN}"
  local account_id
  account_id="$(podman exec "$BOUNDARY_DB_CONTAINER" psql -U boundary -d boundary -t -A -c "SELECT public_id FROM auth_password_account WHERE login_name = '${BOUNDARY_ADMIN_LOGIN}' LIMIT 1;")"
  [[ -n "$account_id" ]] || die "Could not find Boundary password account for ${BOUNDARY_ADMIN_LOGIN}"
  ok "Found account ${account_id}"

  log "Resetting password inside ${BOUNDARY_CONTROLLER_CONTAINER}"
  podman exec -e BOUNDARY_ADDR=http://127.0.0.1:9200 "$BOUNDARY_CONTROLLER_CONTAINER" sh -lc "
    cat >/tmp/recovery.hcl <<'EOF'
kms \"aead\" {
  purpose   = \"recovery\"
  aead_type = \"aes-gcm\"
  key       = \"${BOUNDARY_RECOVERY_KEY}\"
  key_id    = \"global_recovery\"
}
EOF
    printf '%s\n' '${BOUNDARY_NEW_PASSWORD}' >/tmp/newpass.txt
    export BOUNDARY_RECOVERY_CONFIG=/tmp/recovery.hcl
    boundary accounts set-password -id=${account_id} -password=file:///tmp/newpass.txt >/dev/null
    rm -f /tmp/recovery.hcl /tmp/newpass.txt
  "
  ok "Boundary admin password reset for ${BOUNDARY_ADMIN_LOGIN}"
  printf 'New password: %s\n' "$BOUNDARY_NEW_PASSWORD"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    sync-vault-token) shift; sync_vault_token "$@" ;;
    reset-admin) shift; reset_admin "$@" ;;
    -h|--help|"") usage ;;
    *) die "Unknown command: $cmd" ;;
  esac
}

main "$@"
