#!/bin/bash
set -euo pipefail

# =============================================================================
# create_boundary_users.sh
# =============================================================================
# Create Boundary user accounts for authentication
#
# This script creates user accounts in Boundary's password auth method
# so users can log into Boundary and access resources.
#
# Usage:
#   ./create_boundary_users.sh [OPTIONS]
#
# Options:
#   --users <user1,user2,...>  Comma-separated list of usernames
#   --auth-method-id <id>      Auth method ID (default: ampw_8RfTaBwDa2)
#   --org-id <id>              Org scope ID (default: o_7a1VQLLGUg)
#   --default-password <pass>  Default password for all users (default: Password123!)
#   --help                     Show this help
#
# Environment Variables:
#   BOUNDARY_ADDR              Boundary address (default: http://localhost:9200)
#   BOUNDARY_PASSWORD          Boundary admin password (default: Password123!)
#
# Author: Bob (AI Assistant)
# Version: 1.0.0
# =============================================================================

# =============================================================================
# CONFIGURATION
# =============================================================================

# Default users
DEFAULT_USERS="danielle,oliver,alice,dennis"

# Boundary configuration
BOUNDARY_ADDR="${BOUNDARY_ADDR:-http://localhost:9200}"
BOUNDARY_AUTH_METHOD_ID="${BOUNDARY_AUTH_METHOD_ID:-ampw_8RfTaBwDa2}"
BOUNDARY_ADMIN_LOGIN="${BOUNDARY_ADMIN_LOGIN:-admin}"
BOUNDARY_PASSWORD="${BOUNDARY_PASSWORD:-Password123!}"

# Default Boundary resource IDs
DEFAULT_ORG_ID="o_7a1VQLLGUg"
DEFAULT_USER_SCOPE="global"  # Users must be in same scope as auth method
DEFAULT_USER_PASSWORD="Password123!"

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

USERS=""
AUTH_METHOD_ID="${BOUNDARY_AUTH_METHOD_ID}"
ORG_ID="${DEFAULT_ORG_ID}"
USER_SCOPE="${DEFAULT_USER_SCOPE}"
USER_PASSWORD="${DEFAULT_USER_PASSWORD}"

usage() {
  cat <<EOF
${BOLD}Create Boundary User Accounts${NC}

${BOLD}Usage:${NC}
  $0 [OPTIONS]

${BOLD}Options:${NC}
  --users <user1,user2,...>  Comma-separated list of usernames
                             (default: danielle,oliver,alice,dennis)
  --auth-method-id <id>      Auth method ID (default: ${BOUNDARY_AUTH_METHOD_ID})
  --org-id <id>              Org scope ID (default: ${DEFAULT_ORG_ID})
  --default-password <pass>  Default password for all users (default: Password123!)
  --help                     Show this help

${BOLD}Examples:${NC}
  # Create all default users
  $0

  # Create specific users
  $0 --users alice,bob,charlie

  # Create users with custom password
  $0 --default-password "MySecurePass123!"

${BOLD}Environment Variables:${NC}
  BOUNDARY_ADDR       Boundary address (default: http://localhost:9200)
  BOUNDARY_PASSWORD   Boundary admin password (default: Password123!)

${BOLD}What This Does:${NC}
  1. Creates user accounts in Boundary
  2. Creates password auth accounts for each user
  3. Links accounts to users
  4. Users can then log into Boundary with their credentials

${BOLD}After Running:${NC}
  Users can log in at: ${BOUNDARY_ADDR}
  Username: <username>
  Password: ${USER_PASSWORD}

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --users)
      USERS="${2:-}"
      shift 2
      ;;
    --auth-method-id)
      AUTH_METHOD_ID="${2:-}"
      shift 2
      ;;
    --org-id)
      ORG_ID="${2:-}"
      shift 2
      ;;
    --default-password)
      USER_PASSWORD="${2:-}"
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

# Use default users if not specified
if [[ -z "$USERS" ]]; then
  USERS="$DEFAULT_USERS"
fi

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

# Check prerequisites
check_prerequisites() {
  log_section "Checking Prerequisites"
  
  # Check Boundary CLI
  if ! command -v boundary &> /dev/null; then
    fail "boundary CLI not found"
  fi
  log_success "boundary CLI found"
  
  # Check jq
  if ! command -v jq &> /dev/null; then
    fail "jq not found"
  fi
  log_success "jq found"
}

# Authenticate to Boundary
authenticate_boundary() {
  log_section "Authenticating to Boundary"
  
  # Check if already authenticated
  if boundary scopes list > /dev/null 2>&1; then
    log_success "Already authenticated to Boundary"
  else
    # Write password to temp file
    local pass_file
    pass_file=$(mktemp)
    trap 'rm -f "$pass_file"' RETURN
    echo "${BOUNDARY_PASSWORD}" > "$pass_file"
    
    if boundary authenticate password \
        -auth-method-id="${AUTH_METHOD_ID}" \
        -login-name="${BOUNDARY_ADMIN_LOGIN}" \
        -password="file://${pass_file}" > /dev/null 2>&1; then
      log_success "Authenticated to Boundary"
    else
      fail "Boundary authentication failed"
    fi
  fi
  
  # Detect the auth method's scope (users must be in same scope)
  log_info "Detecting auth method scope..."
  local auth_scope
  auth_scope=$(boundary auth-methods read -id="${AUTH_METHOD_ID}" -format=json 2>/dev/null | jq -r '.item.scope_id')
  
  if [[ -n "$auth_scope" && "$auth_scope" != "null" ]]; then
    USER_SCOPE="$auth_scope"
    log_success "Auth method scope detected: ${USER_SCOPE}"
  else
    log_warning "Could not detect auth method scope, using: ${USER_SCOPE}"
  fi
}

# Create Boundary user
create_boundary_user() {
  local username="$1"
  
  log_info "Checking for existing user: ${username}" >&2
  
  # Check if user already exists (handle null items gracefully)
  local existing_user
  local users_json
  users_json=$(boundary users list -scope-id="${USER_SCOPE}" -format=json 2>/dev/null)
  
  if [[ -n "$users_json" ]]; then
    existing_user=$(echo "$users_json" | jq -r ".items[]? | select(.name==\"${username}\") | .id" 2>/dev/null | head -1)
  fi
  
  if [[ -n "$existing_user" ]]; then
    log_success "User '${username}' already exists (${existing_user})" >&2
    echo "$existing_user"
    return 0
  fi
  
  # Create user
  log_info "Creating new user in scope '${USER_SCOPE}': ${username}" >&2
  local user_id
  user_id=$(boundary users create \
    -scope-id="${USER_SCOPE}" \
    -name="${username}" \
    -description="User account for ${username}" \
    -format=json 2>/dev/null | jq -r '.item.id')
  
  if [[ -n "$user_id" && "$user_id" != "null" ]]; then
    log_success "User created: ${user_id}" >&2
    echo "$user_id"
  else
    log_error "Failed to create user '${username}'" >&2
    return 1
  fi
}

# Create password auth account
create_auth_account() {
  local username="$1"
  local user_id="$2"
  
  log_info "Checking for existing auth account: ${username}" >&2
  
  # Check if account already exists (handle null items gracefully)
  local existing_account
  local accounts_json
  accounts_json=$(boundary accounts list -auth-method-id="${AUTH_METHOD_ID}" -format=json 2>/dev/null)
  
  if [[ -n "$accounts_json" ]]; then
    existing_account=$(echo "$accounts_json" | jq -r ".items[]? | select(.attributes.login_name==\"${username}\") | .id" 2>/dev/null | head -1)
  fi
  
  if [[ -n "$existing_account" ]]; then
    log_success "Auth account already exists (${existing_account})" >&2
    echo "$existing_account"
    return 0
  fi
  
  # Create password account
  log_info "Creating new auth account: ${username}" >&2
  local account_id
  local pass_file
  pass_file=$(mktemp)
  trap 'rm -f "$pass_file"' RETURN
  echo "${USER_PASSWORD}" > "$pass_file"
  
  account_id=$(boundary accounts create password \
    -auth-method-id="${AUTH_METHOD_ID}" \
    -login-name="${username}" \
    -password="file://${pass_file}" \
    -format=json 2>/dev/null | jq -r '.item.id')
  
  if [[ -n "$account_id" && "$account_id" != "null" ]]; then
    log_success "Auth account created: ${account_id}" >&2
    echo "$account_id"
  else
    log_error "Failed to create auth account for '${username}'" >&2
    return 1
  fi
}

# Link account to user
link_account_to_user() {
  local username="$1"
  local user_id="$2"
  local account_id="$3"
  
  log_info "Checking if account is linked to user: ${username}" >&2
  
  # Check if already linked
  local user_info
  user_info=$(boundary users read -id="${user_id}" -format=json 2>/dev/null)
  
  if [[ -n "$user_info" ]]; then
    local is_linked
    is_linked=$(echo "$user_info" | jq -r ".item.account_ids[]? | select(. == \"${account_id}\")" 2>/dev/null)
    
    if [[ -n "$is_linked" ]]; then
      log_success "Account already linked to user" >&2
      return 0
    fi
  fi
  
  # Link account to user
  log_info "Linking auth account to user: ${username}" >&2
  local link_output
  link_output=$(boundary users add-accounts \
      -id="${user_id}" \
      -account="${account_id}" 2>&1)
  local link_result=$?
  
  if [[ $link_result -eq 0 ]]; then
    log_success "Account linked to user" >&2
    return 0
  else
    # Check if error is because it's already linked
    if echo "$link_output" | grep -qi "already associated\|already exists\|already a member"; then
      log_success "Account already linked to user" >&2
      return 0
    else
      log_error "Failed to link account to user" >&2
      log_error "Error: $(echo "$link_output" | head -1)" >&2
      return 1
    fi
  fi
}

# Process single user
process_user() {
  local username="$1"
  
  log_section "Processing User: ${username}"
  
  # Step 1: Create Boundary user
  local user_id
  user_id=$(create_boundary_user "$username")
  local user_result=$?
  
  if [[ $user_result -ne 0 || -z "$user_id" ]]; then
    log_error "Failed to create user '${username}'"
    return 1
  fi
  
  # Step 2: Create password auth account
  local account_id
  account_id=$(create_auth_account "$username" "$user_id")
  local account_result=$?
  
  if [[ $account_result -ne 0 || -z "$account_id" ]]; then
    log_error "Failed to create auth account for '${username}'"
    return 1
  fi
  
  # Step 3: Link account to user (don't fail if this fails)
  if link_account_to_user "$username" "$user_id" "$account_id"; then
    log_success "User '${username}' setup complete"
  else
    log_warning "User '${username}' created but account linking had issues"
  fi
  echo ""
}

# Show summary
show_summary() {
  log_header "Setup Complete"
  
  echo -e "${GREEN}${BOLD}Status:${NC} All users created"
  echo ""
  echo -e "${BOLD}Configuration:${NC}"
  echo -e "  ${CYAN}•${NC} Users: ${USERS}"
  echo -e "  ${CYAN}•${NC} User Scope: ${USER_SCOPE}"
  echo -e "  ${CYAN}•${NC} Auth Method: ${AUTH_METHOD_ID}"
  echo -e "  ${CYAN}•${NC} Default Password: ${USER_PASSWORD}"
  echo ""
  
  # List created users
  echo -e "${BOLD}Created Users:${NC}"
  IFS=',' read -ra USER_ARRAY <<< "$USERS"
  for username in "${USER_ARRAY[@]}"; do
    username=$(echo "$username" | xargs)
    local user_id
    user_id=$(boundary users list -scope-id="${USER_SCOPE}" -format=json 2>/dev/null | \
      jq -r ".items[]? | select(.name==\"${username}\") | .id" | head -1)
    
    if [[ -n "$user_id" ]]; then
      echo -e "  ${GREEN}•${NC} ${username} (${user_id})"
    fi
  done
  echo ""
  
  echo -e "${BOLD}Login Information:${NC}"
  echo -e "  ${CYAN}•${NC} URL: ${BOUNDARY_ADDR}"
  echo -e "  ${CYAN}•${NC} Username: <username>"
  echo -e "  ${CYAN}•${NC} Password: ${USER_PASSWORD}"
  echo ""
  
  echo -e "${BOLD}Next Steps:${NC}"
  echo ""
  echo -e "${YELLOW}1.${NC} Users can now log into Boundary:"
  echo -e "   ${DIM}${BOUNDARY_ADDR}${NC}"
  echo ""
  echo -e "${YELLOW}2.${NC} Assign users to roles for permissions:"
  echo -e "   ${DIM}boundary roles add-principals -id=<role-id> -principal=<user-id>${NC}"
  echo ""
  echo -e "${YELLOW}3.${NC} View all users:"
  echo -e "   ${DIM}boundary users list -scope-id=${ORG_ID}${NC}"
  echo ""
  echo -e "${YELLOW}4.${NC} Change user password:"
  echo -e "   ${DIM}boundary accounts set-password -id=<account-id>${NC}"
  echo ""
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
  log_header "Create Boundary User Accounts"
  
  echo -e "${BOLD}Configuration:${NC}"
  echo -e "  ${CYAN}•${NC} Users: ${USERS}"
  echo -e "  ${CYAN}•${NC} User Scope: ${USER_SCOPE}"
  echo -e "  ${CYAN}•${NC} Auth Method: ${AUTH_METHOD_ID}"
  echo -e "  ${CYAN}•${NC} Default Password: ${USER_PASSWORD}"
  echo ""
  
  check_prerequisites
  authenticate_boundary
  
  # Process each user
  IFS=',' read -ra USER_ARRAY <<< "$USERS"
  for username in "${USER_ARRAY[@]}"; do
    # Trim whitespace
    username=$(echo "$username" | xargs)
    process_user "$username"
  done
  
  show_summary
}

# Run main function
main "$@"

# Made with Bob