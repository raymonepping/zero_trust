#!/bin/bash
set -euo pipefail

# =============================================================================
# setup_os_rotation.sh
# =============================================================================
# Comprehensive setup script for Vault OS Secrets Engine Plugin
# Handles initial setup AND post-restart restoration
#
# This script consolidates:
# - install_vault_os_plugin.sh
# - reload_vault_os_plugin.sh
# - restore_vault_os_engine.sh
# - setup_os_secrets_engine.sh
# - setup_vault_os_plugin.sh
#
# Usage:
#   ./setup_os_rotation.sh [OPTIONS]
#
# Options:
#   --install         Download and install plugin binary (first-time setup)
#   --restore         Restore configuration after Vault restart (default)
#   --force-download  Force re-download of plugin binary
#   --skip-accounts   Skip account restoration
#   --container-engine <docker|podman>  Specify container engine (default: auto-detect)
#   --help            Show this help
#
# Author: Bob (AI Assistant)
# Version: 1.0.0
# =============================================================================

# =============================================================================
# CONFIGURATION
# =============================================================================

PLUGIN_VERSION="0.1.0-rc3+ent"
PLUGIN_NAME="vault-plugin-secrets-os"
PLUGIN_DIR="../../plugins"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
SSH_CONTAINER="${SSH_CONTAINER:-zero_trust_boundary_ssh}"
NETWORK_NAME="${NETWORK_NAME:-zero_trust_net-data}"

# =============================================================================
# COLORS
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# =============================================================================
# COMMAND-LINE OPTIONS
# =============================================================================

MODE="restore"  # Default mode
FORCE_DOWNLOAD=false
SKIP_ACCOUNTS=false
CONTAINER_ENGINE=""

usage() {
  cat <<EOF
${BOLD}Vault OS Secrets Engine - Comprehensive Setup${NC}

${BOLD}Usage:${NC}
  $0 [OPTIONS]

${BOLD}Options:${NC}
  --install                     Download and install plugin binary (first-time)
  --restore                     Restore configuration after Vault restart (default)
  --force-download              Force re-download of plugin binary
  --skip-accounts               Skip account restoration
  --container-engine <engine>   Specify docker or podman (default: auto-detect)
  --help                        Show this help

${BOLD}Modes:${NC}
  ${CYAN}install${NC}  - First-time setup: downloads plugin, registers, configures
  ${CYAN}restore${NC}  - Post-restart: re-registers plugin, restores configuration

${BOLD}Examples:${NC}
  # First-time installation
  $0 --install

  # After Vault restart (default)
  $0
  $0 --restore

  # Force re-download and reinstall
  $0 --install --force-download

  # Restore without re-creating accounts
  $0 --restore --skip-accounts

${BOLD}Environment Variables:${NC}
  VAULT_ADDR          Vault address (default: http://127.0.0.1:8200)
  VAULT_TOKEN         Vault authentication token (required)
  SSH_CONTAINER       SSH container name (default: zero_trust_boundary_ssh)
  NETWORK_NAME        Docker network name (default: zero_trust_net-data)

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      MODE="install"
      shift
      ;;
    --restore)
      MODE="restore"
      shift
      ;;
    --force-download)
      FORCE_DOWNLOAD=true
      shift
      ;;
    --skip-accounts)
      SKIP_ACCOUNTS=true
      shift
      ;;
    --container-engine)
      CONTAINER_ENGINE="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}" >&2
      usage
      exit 1
      ;;
  esac
done

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log_header() {
  echo ""
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${BLUE}  $1${NC}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════${NC}"
  echo ""
}

log_section() {
  echo ""
  echo -e "${BOLD}${CYAN}▸ $1${NC}"
}

log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
  echo -e "${RED}✗${NC} $1" >&2
}

fail() {
  log_error "$1"
  exit 1
}

# Detect container engine
detect_container_engine() {
  if [[ -n "$CONTAINER_ENGINE" ]]; then
    if ! command -v "$CONTAINER_ENGINE" &> /dev/null; then
      fail "Specified container engine '$CONTAINER_ENGINE' not found"
    fi
    echo "$CONTAINER_ENGINE"
    return
  fi
  
  if command -v podman &> /dev/null; then
    echo "podman"
  elif command -v docker &> /dev/null; then
    echo "docker"
  else
    fail "Neither docker nor podman found"
  fi
}

# Check prerequisites
check_prerequisites() {
  log_section "Checking Prerequisites"
  
  # Check Vault CLI
  if ! command -v vault &> /dev/null; then
    fail "vault CLI not found. Please install HashiCorp Vault."
  fi
  log_success "vault CLI found"
  
  # Check jq
  if ! command -v jq &> /dev/null; then
    fail "jq not found. Please install jq."
  fi
  log_success "jq found"
  
  # Check Vault connection
  export VAULT_ADDR
  if ! vault status > /dev/null 2>&1; then
    fail "Cannot connect to Vault at ${VAULT_ADDR}"
  fi
  log_success "Vault is accessible at ${VAULT_ADDR}"
  
  # Check Vault authentication
  if [[ -z "$VAULT_TOKEN" ]]; then
    if ! vault token lookup > /dev/null 2>&1; then
      fail "Not authenticated to Vault. Set VAULT_TOKEN or run 'vault login'"
    fi
  else
    export VAULT_TOKEN
  fi
  log_success "Vault authentication verified"
  
  # Detect container engine
  CONTAINER_ENGINE=$(detect_container_engine)
  log_success "Container engine: ${CONTAINER_ENGINE}"
  
  # Check if SSH container is running
  if ! ${CONTAINER_ENGINE} ps --format '{{.Names}}' | grep -q "^${SSH_CONTAINER}$"; then
    log_warning "SSH container '${SSH_CONTAINER}' is not running"
    log_info "Some features may not work without the SSH target"
  else
    log_success "SSH container '${SSH_CONTAINER}' is running"
  fi
}

# Download and install plugin binary
install_plugin_binary() {
  log_section "Installing Plugin Binary"
  
  # Detect OS and architecture
  local os=$(uname -s | tr '[:upper:]' '[:lower:]')
  local arch=$(uname -m)
  
  case $arch in
    x86_64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) fail "Unsupported architecture: $arch" ;;
  esac
  
  log_info "System: ${os}_${arch}"
  
  # Create plugins directory
  mkdir -p "$PLUGIN_DIR"
  
  local plugin_path="${PLUGIN_DIR}/${PLUGIN_NAME}"
  
  # Check if plugin exists and skip download if not forcing
  if [[ -f "$plugin_path" && "$FORCE_DOWNLOAD" == false ]]; then
    log_success "Plugin binary already exists at ${plugin_path}"
    log_info "Use --force-download to re-download"
    return 0
  fi
  
  # Download URL
  local download_url="https://releases.hashicorp.com/${PLUGIN_NAME}/${PLUGIN_VERSION}/${PLUGIN_NAME}_${PLUGIN_VERSION}_${os}_${arch}.zip"
  
  log_info "Downloading from: ${download_url}"
  
  # Download
  if command -v curl &> /dev/null; then
    if ! curl -fsSL -o "/tmp/${PLUGIN_NAME}.zip" "$download_url"; then
      fail "Download failed. Check version ${PLUGIN_VERSION} exists for ${os}_${arch}"
    fi
  elif command -v wget &> /dev/null; then
    if ! wget -q -O "/tmp/${PLUGIN_NAME}.zip" "$download_url"; then
      fail "Download failed. Check version ${PLUGIN_VERSION} exists for ${os}_${arch}"
    fi
  else
    fail "Neither curl nor wget found"
  fi
  
  log_success "Download complete"
  
  # Extract
  log_info "Extracting plugin..."
  if ! unzip -o "/tmp/${PLUGIN_NAME}.zip" -d "$PLUGIN_DIR/" > /dev/null 2>&1; then
    fail "Failed to extract plugin"
  fi
  rm "/tmp/${PLUGIN_NAME}.zip"
  
  # Make executable
  chmod +x "$plugin_path"
  log_success "Plugin installed at ${plugin_path}"
  
  # Restart Vault container to pick up new plugin
  log_info "Restarting Vault container..."
  ${CONTAINER_ENGINE} restart zero_trust_vault > /dev/null 2>&1 || log_warning "Could not restart Vault container"
  
  # Wait for Vault to be ready
  log_info "Waiting for Vault to be ready..."
  for i in {1..30}; do
    if vault status > /dev/null 2>&1; then
      log_success "Vault is ready"
      return 0
    fi
    sleep 1
  done
  
  fail "Vault did not become ready after restart"
}

# Register plugin with Vault
register_plugin() {
  log_section "Registering Plugin"
  
  # Check if already registered
  if vault plugin list secret -format=json 2>/dev/null | jq -e '.[] | select(.name == "'"${PLUGIN_NAME}"'")' > /dev/null 2>&1; then
    log_info "Plugin already registered, re-registering..."
  fi
  
  # Calculate SHA256 from inside Vault container
  local plugin_sha
  plugin_sha=$(${CONTAINER_ENGINE} exec zero_trust_vault sha256sum "/vault/plugins/${PLUGIN_NAME}" 2>/dev/null | cut -d' ' -f1)
  
  if [[ -z "$plugin_sha" ]]; then
    fail "Could not calculate plugin SHA256. Is the plugin in the Vault container?"
  fi
  
  log_info "Plugin SHA256: ${plugin_sha}"
  
  # Register
  if vault plugin register \
      -sha256="${plugin_sha}" \
      -command="${PLUGIN_NAME}" \
      secret "${PLUGIN_NAME}"; then
    log_success "Plugin registered successfully"
  else
    fail "Plugin registration failed"
  fi
}

# Enable secrets engine
enable_secrets_engine() {
  log_section "Enabling Secrets Engine"
  
  # Check if already enabled
  if vault secrets list -format=json 2>/dev/null | jq -e 'has("os/")' > /dev/null 2>&1; then
    log_success "OS Secrets Engine already enabled at 'os/'"
    return 0
  fi
  
  # Enable
  if vault secrets enable -path=os "${PLUGIN_NAME}"; then
    log_success "OS Secrets Engine enabled at 'os/'"
  else
    fail "Failed to enable secrets engine"
  fi
}

# Reload plugin (for post-restart scenarios)
reload_plugin() {
  log_section "Reloading Plugin"
  
  log_info "Reloading plugin to restore functionality..."
  
  if vault plugin reload -plugin "${PLUGIN_NAME}" 2>/dev/null; then
    log_success "Plugin reloaded successfully"
  else
    log_warning "Plugin reload failed, trying alternative method..."
    
    # Alternative: disable and re-enable
    vault secrets disable os/ 2>/dev/null || true
    sleep 2
    
    if vault secrets enable -path=os "${PLUGIN_NAME}"; then
      log_success "Secrets engine re-enabled successfully"
    else
      fail "Failed to restore secrets engine"
    fi
  fi
}

# Create password policy
create_password_policy() {
  log_section "Creating Password Policy"
  
  # Check if policy exists
  if vault read sys/policies/password/rhel-policy > /dev/null 2>&1; then
    log_success "Password policy 'rhel-policy' already exists"
    return 0
  fi
  
  log_info "Creating password policy 'rhel-policy'..."
  
  vault write sys/policies/password/rhel-policy policy=-<<'EOF'
length=20
rule "charset" {
  charset = "abcdefghijklmnopqrstuvwxyz"
  min-chars = 1
}
rule "charset" {
  charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  min-chars = 1
}
rule "charset" {
  charset = "0123456789"
  min-chars = 1
}
rule "charset" {
  charset = "!@#%^&*"
  min-chars = 1
}
EOF
  
  log_success "Password policy created"
}

# Configure OS secrets engine
configure_secrets_engine() {
  log_section "Configuring Secrets Engine"
  
  log_info "Setting SSH host key trust..."
  
  if vault write os/config ssh_host_key_trust_on_first_use=true; then
    log_success "SSH host key trust configured"
  else
    log_warning "Could not configure SSH host key trust (may already be set)"
  fi
}

# Configure SSH host
configure_ssh_host() {
  log_section "Configuring SSH Host"
  
  # Get SSH container IP
  local ssh_ip
  ssh_ip=$(${CONTAINER_ENGINE} inspect "${SSH_CONTAINER}" \
    --format '{{range $net, $conf := .NetworkSettings.Networks}}{{if eq $net "'"${NETWORK_NAME}"'"}}{{$conf.IPAddress}}{{end}}{{end}}' \
    2>/dev/null || echo "")
  
  if [[ -z "$ssh_ip" ]]; then
    log_warning "Could not detect SSH container IP"
    log_info "SSH host configuration skipped"
    log_info "To configure manually: vault write os/hosts/ssh-host1 address=<ip> port=22"
    return 0
  fi
  
  log_info "SSH Container IP: ${ssh_ip}"
  
  # Configure host
  if vault write os/hosts/ssh-host1 \
      address="${ssh_ip}" \
      port=22; then
    log_success "SSH host 'ssh-host1' configured at ${ssh_ip}:22"
  else
    log_warning "Could not configure SSH host (may already exist)"
  fi
}

# Restore user accounts
restore_accounts() {
  if [[ "$SKIP_ACCOUNTS" == true ]]; then
    log_section "Skipping Account Restoration"
    log_info "Use --skip-accounts=false to restore accounts"
    return 0
  fi
  
  log_section "Checking User Accounts"
  
  # List existing accounts
  local accounts
  accounts=$(vault list -format=json os/hosts/ssh-host1/accounts 2>/dev/null | jq -r '.[]' 2>/dev/null || echo "")
  
  if [[ -z "$accounts" ]]; then
    log_info "No accounts configured"
    log_info "Use add_user.sh to create managed accounts"
  else
    log_success "Found existing accounts:"
    echo "$accounts" | while read -r account; do
      echo -e "  ${GREEN}•${NC} ${account}"
    done
  fi
}

# Verify setup
verify_setup() {
  log_section "Verifying Setup"
  
  local all_good=true
  
  # Check plugin registration
  if vault plugin list secret -format=json 2>/dev/null | jq -e '.[] | select(.name == "'"${PLUGIN_NAME}"'")' > /dev/null 2>&1; then
    log_success "Plugin registered"
  else
    log_error "Plugin not registered"
    all_good=false
  fi
  
  # Check secrets engine
  if vault secrets list -format=json 2>/dev/null | jq -e 'has("os/")' > /dev/null 2>&1; then
    log_success "Secrets engine enabled"
  else
    log_error "Secrets engine not enabled"
    all_good=false
  fi
  
  # Check password policy
  if vault read sys/policies/password/rhel-policy > /dev/null 2>&1; then
    log_success "Password policy exists"
  else
    log_error "Password policy missing"
    all_good=false
  fi
  
  # Check SSH host
  if vault list os/hosts 2>/dev/null | grep -q "ssh-host1"; then
    log_success "SSH host configured"
  else
    log_warning "SSH host not configured (may need manual setup)"
  fi
  
  if [[ "$all_good" == false ]]; then
    fail "Verification failed. Please review errors above."
  fi
  
  log_success "All critical components verified"
}

# Show summary
show_summary() {
  log_header "Setup Complete"
  
  echo -e "${GREEN}${BOLD}Status:${NC} OS Secrets Engine is ready"
  echo ""
  echo -e "${BOLD}Configuration:${NC}"
  echo -e "  ${CYAN}•${NC} Plugin: ${PLUGIN_NAME}"
  echo -e "  ${CYAN}•${NC} Secrets Engine: os/"
  echo -e "  ${CYAN}•${NC} Password Policy: rhel-policy"
  echo -e "  ${CYAN}•${NC} SSH Host: ssh-host1"
  echo ""
  
  # List accounts if any
  local accounts
  accounts=$(vault list -format=json os/hosts/ssh-host1/accounts 2>/dev/null | jq -r '.[]' 2>/dev/null || echo "")
  
  if [[ -n "$accounts" ]]; then
    echo -e "${BOLD}Managed Accounts:${NC}"
    echo "$accounts" | while read -r account; do
      echo -e "  ${GREEN}•${NC} ${account}"
    done
    echo ""
  fi
  
  echo -e "${BOLD}Next Steps:${NC}"
  echo ""
  echo -e "${YELLOW}1.${NC} Add users (if not already configured):"
  echo -e "   ${DIM}./add_user.sh --username boundary${NC}"
  echo ""
  echo -e "${YELLOW}2.${NC} Read credentials:"
  echo -e "   ${DIM}vault read os/hosts/ssh-host1/accounts/<username>/creds${NC}"
  echo ""
  echo -e "${YELLOW}3.${NC} Manually rotate password:"
  echo -e "   ${DIM}vault write -f os/hosts/ssh-host1/accounts/<username>/rotate${NC}"
  echo ""
  echo -e "${YELLOW}4.${NC} Verify rotation:"
  echo -e "   ${DIM}./verify_linux_rotation.sh${NC}"
  echo ""
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
  log_header "Vault OS Secrets Engine Setup"
  
  echo -e "${BOLD}Mode:${NC} ${CYAN}${MODE}${NC}"
  echo -e "${BOLD}Vault:${NC} ${VAULT_ADDR}"
  echo ""
  
  check_prerequisites
  
  case "$MODE" in
    install)
      install_plugin_binary
      register_plugin
      enable_secrets_engine
      create_password_policy
      configure_secrets_engine
      configure_ssh_host
      ;;
    restore)
      register_plugin
      reload_plugin
      create_password_policy
      configure_secrets_engine
      configure_ssh_host
      restore_accounts
      ;;
    *)
      fail "Unknown mode: $MODE"
      ;;
  esac
  
  verify_setup
  show_summary
}

# Run main function
main "$@"

# Made with Bob