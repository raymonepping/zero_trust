#!/usr/bin/env bash
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
BOUNDARY_ADDR="${BOUNDARY_ADDR:-http://localhost:9200}"
SSH_CONTAINER="${SSH_CONTAINER:-zero_trust_boundary_ssh}"
SSH_USER="${SSH_USER:-danielle}"
BOUNDARY_PASSWORD="${BOUNDARY_PASSWORD:-Password123!}"
BOUNDARY_AUTH_METHOD_ID="${BOUNDARY_AUTH_METHOD_ID:-ampw_8RfTaBwDa2}"
BOUNDARY_ORG_SCOPE="${BOUNDARY_ORG_SCOPE:-o_7a1VQLLGUg}"
BOUNDARY_PROJECT_SCOPE="${BOUNDARY_PROJECT_SCOPE:-p_vTsmEn4gLN}"
BOUNDARY_VAULT_CRED_STORE="${BOUNDARY_VAULT_CRED_STORE:-csvlt_s1WV97fBZS}"
BOUNDARY_TARGET_NAME="${BOUNDARY_TARGET_NAME:-boundary-ssh-ubuntu}"
SSH_ROLE_NAME="${SSH_ROLE_NAME:-boundary-ssh}"

C_RESET=$'\033[0m'
C_GREEN=$'\033[0;32m'
C_BLUE=$'\033[0;34m'
C_YELLOW=$'\033[1;33m'
C_RED=$'\033[0;31m'

log() { printf '%s==> %s%s\n' "$C_BLUE" "$1" "$C_RESET"; }
ok() { printf '%s✓ %s%s\n' "$C_GREEN" "$1" "$C_RESET"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$1" "$C_RESET"; }
err() { printf '%s%s%s\n' "$C_RED" "$1" "$C_RESET" >&2; }
die() { err "$1"; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  bootstrap-ssh       Run all SSH-related setup steps
  setup-ssh-ca        Enable Vault SSH CA and trust it in the Ubuntu target
  fix-ssh-role        Ensure the Vault SSH role includes PTY-related extensions
  fix-ssh-pty         Ensure sshd trusts the Vault CA and allows PTY allocation
  setup-ssh-target    Create or update the Boundary SSH target with Vault cert injection

Environment overrides:
  VAULT_ADDR, VAULT_TOKEN, BOUNDARY_ADDR, BOUNDARY_PASSWORD
  SSH_CONTAINER, SSH_USER, SSH_ROLE_NAME
  BOUNDARY_AUTH_METHOD_ID, BOUNDARY_ORG_SCOPE, BOUNDARY_PROJECT_SCOPE
  BOUNDARY_VAULT_CRED_STORE, BOUNDARY_TARGET_NAME
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

require_boundary_password_auth() {
  local pass_file
  pass_file="$(mktemp)"
  trap 'rm -f "$pass_file"' RETURN
  printf '%s\n' "$BOUNDARY_PASSWORD" >"$pass_file"
  boundary authenticate password \
    -auth-method-id="$BOUNDARY_AUTH_METHOD_ID" \
    -login-name=admin \
    -password="file://${pass_file}" >/dev/null
  ok "Authenticated to Boundary"
}

detect_pubkey_file() {
  if [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
    printf '%s\n' "${HOME}/.ssh/id_ed25519.pub"
    return 0
  fi
  if [[ -f "${HOME}/.ssh/id_rsa.pub" ]]; then
    printf '%s\n' "${HOME}/.ssh/id_rsa.pub"
    return 0
  fi
  warn "No SSH public key found. Generating ~/.ssh/id_ed25519"
  ssh-keygen -t ed25519 -f "${HOME}/.ssh/id_ed25519" -N "" -C "$(whoami)@$(hostname)" >/dev/null
  printf '%s\n' "${HOME}/.ssh/id_ed25519.pub"
}

get_ssh_ip() {
  podman inspect "$SSH_CONTAINER" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' \
    | awk 'NF { print; exit }'
}

setup_ssh_ca() {
  require_cmds vault podman ssh-keygen
  require_vault_token
  log "Preparing SSH CA and trusted user setup"

  local pub_key_file pub_key vault_ca_key
  pub_key_file="$(detect_pubkey_file)"
  pub_key="$(cat "$pub_key_file")"
  ok "Using public key ${pub_key_file}"

  if vault secrets list | grep -q '^ssh/'; then
    ok "Vault SSH secrets engine already enabled"
  else
    vault secrets enable ssh >/dev/null
    ok "Enabled Vault SSH secrets engine"
  fi

  if vault read ssh/config/ca >/dev/null 2>&1; then
    ok "Vault SSH CA already configured"
  else
    vault write ssh/config/ca generate_signing_key=true >/dev/null
    ok "Generated Vault SSH CA signing key"
  fi

  vault write "ssh/roles/${SSH_ROLE_NAME}" \
    key_type=ca \
    ttl=30m \
    allow_user_certificates=true \
    allowed_users="${SSH_USER},ubuntu,root" >/dev/null
  ok "Ensured Vault SSH role ${SSH_ROLE_NAME}"

  vault_ca_key="$(vault read -field=public_key ssh/config/ca)"
  podman exec "$SSH_CONTAINER" bash -lc "
    mkdir -p /etc/ssh /home/${SSH_USER}/.ssh
    printf '%s\n' '${vault_ca_key}' > /etc/ssh/trusted-user-ca-keys.pem
    chmod 644 /etc/ssh/trusted-user-ca-keys.pem
    grep -q 'TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem' /etc/ssh/sshd_config || echo 'TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem' >> /etc/ssh/sshd_config
    printf '%s\n' '${pub_key}' >> /home/${SSH_USER}/.ssh/authorized_keys
    chmod 700 /home/${SSH_USER}/.ssh
    chmod 600 /home/${SSH_USER}/.ssh/authorized_keys
    chown -R ${SSH_USER}:${SSH_USER} /home/${SSH_USER}/.ssh
    pkill -HUP sshd || true
  "
  ok "Trusted Vault CA and local public key installed in ${SSH_CONTAINER}"
  printf 'SSH target IP: %s\n' "$(get_ssh_ip)"
}

fix_ssh_role() {
  require_cmds vault curl
  require_vault_token
  log "Updating Vault SSH role extensions for PTY-capable certs"

  local payload
  payload="$(mktemp)"
  trap 'rm -f "$payload"' RETURN
  cat >"$payload" <<EOF
{
  "key_type": "ca",
  "ttl": "30m",
  "allow_user_certificates": true,
  "allowed_users": "${SSH_USER},ubuntu,root",
  "default_extensions": {
    "permit-pty": "",
    "permit-X11-forwarding": "",
    "permit-agent-forwarding": "",
    "permit-port-forwarding": ""
  }
}
EOF

  curl -fsS -X POST \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d @"$payload" \
    "${VAULT_ADDR}/v1/ssh/roles/${SSH_ROLE_NAME}" >/dev/null
  ok "Updated Vault SSH role ${SSH_ROLE_NAME}"
}

fix_ssh_pty() {
  require_cmds podman
  log "Updating sshd configuration inside ${SSH_CONTAINER}"

  podman exec "$SSH_CONTAINER" bash -lc "
    grep -q '^PermitTTY yes' /etc/ssh/sshd_config || echo 'PermitTTY yes' >> /etc/ssh/sshd_config
    grep -q '^PubkeyAuthentication yes' /etc/ssh/sshd_config || sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    grep -q 'TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem' /etc/ssh/sshd_config || echo 'TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem' >> /etc/ssh/sshd_config
    test -f /etc/ssh/trusted-user-ca-keys.pem
    pkill -HUP sshd
  "
  ok "sshd reloaded with PTY and CA trust settings"
}

setup_ssh_target() {
  require_cmds boundary jq podman
  require_boundary_password_auth

  local ssh_ip host_catalog host host_set cred_library target
  ssh_ip="$(get_ssh_ip)"
  [[ -n "$ssh_ip" ]] || die "Could not determine IP for ${SSH_CONTAINER}"
  ok "Detected ${SSH_CONTAINER} IP ${ssh_ip}"

  host_catalog="$(boundary host-catalogs list -scope-id="$BOUNDARY_PROJECT_SCOPE" -format=json | jq -r '.items[]? | select(.name=="ubuntu-hosts") | .id' | head -1)"
  if [[ -z "$host_catalog" ]]; then
    host_catalog="$(boundary host-catalogs create static -scope-id="$BOUNDARY_PROJECT_SCOPE" -name="ubuntu-hosts" -description="Ubuntu SSH hosts" -format=json | jq -r '.item.id')"
    ok "Created host catalog ${host_catalog}"
  else
    ok "Using host catalog ${host_catalog}"
  fi

  host="$(boundary hosts list -host-catalog-id="$host_catalog" -format=json | jq -r '.items[]? | select(.name=="ubuntu-ssh-host") | .id' | head -1)"
  if [[ -z "$host" ]]; then
    host="$(boundary hosts create static -host-catalog-id="$host_catalog" -name="ubuntu-ssh-host" -description="Ubuntu SSH host" -address="$ssh_ip" -format=json | jq -r '.item.id')"
    ok "Created host ${host}"
  else
    boundary hosts update static -id="$host" -address="$ssh_ip" >/dev/null
    ok "Updated host ${host}"
  fi

  host_set="$(boundary host-sets list -host-catalog-id="$host_catalog" -format=json | jq -r '.items[]? | select(.name=="ubuntu-ssh-set") | .id' | head -1)"
  if [[ -z "$host_set" ]]; then
    host_set="$(boundary host-sets create static -host-catalog-id="$host_catalog" -name="ubuntu-ssh-set" -description="Ubuntu SSH host set" -format=json | jq -r '.item.id')"
    ok "Created host set ${host_set}"
  else
    ok "Using host set ${host_set}"
  fi
  boundary host-sets add-hosts -id="$host_set" -host="$host" >/dev/null 2>&1 || true

  cred_library="$(boundary credential-libraries list -credential-store-id="$BOUNDARY_VAULT_CRED_STORE" -format=json | jq -r '.items[]? | select(.name=="ssh-cert-library") | .id' | head -1)"
  if [[ -z "$cred_library" ]]; then
    cred_library="$(boundary credential-libraries create vault-ssh-certificate \
      -credential-store-id="$BOUNDARY_VAULT_CRED_STORE" \
      -vault-path="ssh/sign/${SSH_ROLE_NAME}" \
      -username="$SSH_USER" \
      -name="ssh-cert-library" \
      -description="Vault SSH certificate library for Ubuntu" \
      -format=json | jq -r '.item.id')"
    ok "Created credential library ${cred_library}"
  else
    ok "Using credential library ${cred_library}"
  fi

  target="$(boundary targets list -scope-id="$BOUNDARY_PROJECT_SCOPE" -format=json | jq -r --arg name "$BOUNDARY_TARGET_NAME" '.items[]? | select(.name==$name) | .id' | head -1)"
  if [[ -z "$target" ]]; then
    target="$(boundary targets create ssh \
      -scope-id="$BOUNDARY_PROJECT_SCOPE" \
      -name="$BOUNDARY_TARGET_NAME" \
      -description="SSH access to Ubuntu container with Vault credentials" \
      -default-port=22 \
      -session-connection-limit=-1 \
      -format=json | jq -r '.item.id')"
    ok "Created target ${target}"
  else
    ok "Using target ${target}"
  fi

  boundary targets add-host-sources -id="$target" -host-source="$host_set" >/dev/null 2>&1 || true
  boundary targets add-credential-sources -id="$target" -injected-application-credential-source="$cred_library" >/dev/null 2>&1 || true
  ok "Target ${target} is wired to host set and Vault credential library"
  printf 'Connect with: boundary connect ssh -target-id=%s\n' "$target"
}

bootstrap_ssh() {
  setup_ssh_ca
  fix_ssh_role
  fix_ssh_pty
  setup_ssh_target
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    bootstrap-ssh) shift; bootstrap_ssh "$@" ;;
    setup-ssh-ca) shift; setup_ssh_ca "$@" ;;
    fix-ssh-role) shift; fix_ssh_role "$@" ;;
    fix-ssh-pty) shift; fix_ssh_pty "$@" ;;
    setup-ssh-target) shift; setup_ssh_target "$@" ;;
    -h|--help|"") usage ;;
    *) die "Unknown command: $cmd" ;;
  esac
}

main "$@"
