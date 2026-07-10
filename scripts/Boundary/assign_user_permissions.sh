#!/bin/bash
set -euo pipefail

# =============================================================================
# assign_user_permissions.sh
# =============================================================================
# Assign Boundary users to roles for target access
#
# This script creates a role with grants to access SSH targets and assigns
# users to that role so they can connect via Boundary.
#
# Usage:
#   ./assign_user_permissions.sh [OPTIONS]
#
# Options:
#   --users <user1,user2,...>  Comma-separated list of usernames
#   --project-id <id>          Project scope (default: p_vTsmEn4gLN)
#   --target-id <id>           Target ID to grant access (default: tssh_JCd6mEiYqd)
#   --role-name <name>         Role name (default: ssh-users)
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
DEFAULT_PROJECT_ID="p_vTsmEn4gLN"
DEFAULT_TARGET_ID="tssh_JCd6mEiYqd"
DEFAULT_ROLE_NAME="ssh-users"

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
PROJECT_ID="${DEFAULT_PROJECT_ID}"
TARGET_ID="${DEFAULT_TARGET_ID}"
ROLE_NAME="${DEFAULT_ROLE_NAME}"

usage() {
  cat <<EOF
${BOLD}Assign Boundary User Permissions${NC}

${BOLD}Usage:${NC}
  $0 [OPTIONS]

${BOLD}Options:${NC}
  --users <user1,user2,...>  Comma-separated list of usernames
                             (default: danielle,oliver,alice,dennis)
  --project-id <id>          Project scope (default: ${DEFAULT_PROJECT_ID})
  --target-id <id>           Target ID to grant access (default: ${DEFAULT_TARGET_ID})
  --role-name <name>         Role name (default: ${DEFAULT_ROLE_NAME})
  --help                     Show this help

${BOLD}Examples:${NC}
  # Assign default users to SSH target
  $0

  # Assign specific users
  $0 --users alice,bob,charlie

  # Assign to different target
  $0 --target-id tssh_xyz123

${BOLD}Environment Variables:${NC}
  BOUNDARY_ADDR       Boundary address (default: http://localhost:9200)
  BOUNDARY_PASSWORD   Boundary admin password (default: Password123!)

${BOLD}What This Does:${NC}
  1. Creates a role with grants to access the SSH target
  2. Assigns users as principals to the role
  3. Users can then connect to the target via Boundary

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --users)
      USERS="${2:-}"
      shift 2
      ;;
    --project-id)
      PROJECT_ID="${2:-}"
      shift 2
      ;;
    --target-id)
      TARGET_ID="${2:-}"
      shift 2
      ;;
    --role-name)
      ROLE_NAME="${2:-}"
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
    return 0
  fi
  
  # Write password to temp file
  local pass_file
  pass_file=$(mktemp)
  trap 'rm -f "$pass_file"' RETURN
  echo "${BOUNDARY_PASSWORD}" > "$pass_file"
  
  if boundary authenticate password \
      -auth-method-id="${BOUNDARY_AUTH_METHOD_ID}" \
      -login-name="${BOUNDARY_ADMIN_LOGIN}" \
      -password="file://${pass_file}" > /dev/null 2>&1; then
    log_success "Authenticated to Boundary"
  else
    fail "Boundary authentication failed"
  fi
}

# Get user ID by username
get_user_id() {
  local username="$1"
  
  # Search in global scope first
  local user_id
  user_id=$(boundary users list -scope-id=global -format=json 2>/dev/null | \
    jq -r ".items[]? | select(.name==\"${username}\") | .id" | head -1)
  
  if [[ -n "$user_id" ]]; then
    log_info "Found user '${username}' in global scope" >&2
    echo "$user_id"
    return 0
  fi
  
  # Try org scope if not found in global
  log_info "User not in global scope, checking org scope..." >&2
  user_id=$(boundary users list -scope-id="${PROJECT_ID}" -format=json 2>/dev/null | \
    jq -r ".items[]? | select(.name==\"${username}\") | .id" | head -1)
  
  if [[ -n "$user_id" ]]; then
    log_warning "User '${username}' found in org scope (${PROJECT_ID}), but should be in global scope for this auth method" >&2
    log_warning "Consider recreating user in global scope with create_boundary_users.sh" >&2
    echo "$user_id"
    return 0
  fi
  
  # If not found anywhere, log and return error
  log_error "User '${username}' not found in global or org scope" >&2
  return 1
}

# Create or get role
create_or_get_role() {
  log_section "Creating or Getting Role" >&2
  
  log_info "Checking for existing role '${ROLE_NAME}'..." >&2
  
  # Check if role exists
  local existing_role
  existing_role=$(boundary roles list -scope-id="${PROJECT_ID}" -format=json 2>/dev/null | \
    jq -r ".items[]? | select(.name==\"${ROLE_NAME}\") | .id" | head -1)
  
  if [[ -n "$existing_role" ]]; then
    log_success "Role '${ROLE_NAME}' already exists (${existing_role})" >&2
    echo "$existing_role"
    return 0
  fi
  
  # Create role
  log_info "Creating new role '${ROLE_NAME}'..." >&2
  local role_id
  role_id=$(boundary roles create \
    -scope-id="${PROJECT_ID}" \
    -name="${ROLE_NAME}" \
    -description="Role for SSH target access" \
    -format=json 2>/dev/null | jq -r '.item.id')
  
  if [[ -n "$role_id" && "$role_id" != "null" ]]; then
    log_success "Role created: ${role_id}" >&2
    echo "$role_id"
  else
    log_error "Failed to create role" >&2
    return 1
  fi
}

# Add grant to role
add_grant_to_role() {
  local role_id="$1"
  
  log_section "Adding Grants to Role"
  
  log_info "Adding authorize-session grant for target ${TARGET_ID}..."
  
  # Add grant for specific target
  if boundary roles add-grants \
      -id="${role_id}" \
      -grant="ids=${TARGET_ID};actions=authorize-session" > /dev/null 2>&1; then
    log_success "Grant added for target ${TARGET_ID}"
  else
    # May already exist
    log_warning "Could not add grant (may already exist)"
  fi
  
  # Also add read grant for the target
  log_info "Adding read grant for target ${TARGET_ID}..."
  if boundary roles add-grants \
      -id="${role_id}" \
      -grant="ids=${TARGET_ID};actions=read" > /dev/null 2>&1; then
    log_success "Read grant added"
  else
    log_warning "Could not add read grant (may already exist)"
  fi
}

# Assign user to role
assign_user_to_role() {
  local username="$1"
  local role_id="$2"
  
  log_info "Assigning user '${username}' to role..." >&2
  
  # Get user ID
  local user_id
  user_id=$(get_user_id "$username")
  local get_result=$?
  
  if [[ $get_result -ne 0 || -z "$user_id" ]]; then
    log_error "User '${username}' not found" >&2
    return 1
  fi
  
  log_info "User ID: ${user_id}" >&2
  
  # Add user as principal
  if boundary roles add-principals \
      -id="${role_id}" \
      -principal="${user_id}" > /dev/null 2>&1; then
    log_success "User '${username}' assigned to role" >&2
  else
    # May already be assigned
    log_warning "Could not assign user (may already be assigned)" >&2
  fi
}

# Show summary
show_summary() {
  log_header "Setup Complete"
  
  echo -e "${GREEN}${BOLD}Status:${NC} Users assigned to role"
  echo ""
  echo -e "${BOLD}Configuration:${NC}"
  echo -e "  ${CYAN}•${NC} Users: ${USERS}"
  echo -e "  ${CYAN}•${NC} Role: ${ROLE_NAME}"
  echo -e "  ${CYAN}•${NC} Project: ${PROJECT_ID}"
  echo -e "  ${CYAN}•${NC} Target: ${TARGET_ID}"
  echo ""
  
  echo -e "${BOLD}Grants:${NC}"
  echo -e "  ${GREEN}•${NC} authorize-session on ${TARGET_ID}"
  echo -e "  ${GREEN}•${NC} read on ${TARGET_ID}"
  echo ""
  
  echo -e "${BOLD}Next Steps:${NC}"
  echo ""
  echo -e "${YELLOW}1.${NC} Users can now connect to the target:"
  echo -e "   ${DIM}boundary connect ssh -target-id=${TARGET_ID}${NC}"
  echo ""
  echo -e "${YELLOW}2.${NC} Or by target name:"
  echo -e "   ${DIM}boundary connect ssh <target-name>${NC}"
  echo ""
  echo -e "${YELLOW}3.${NC} View role details:"
  echo -e "   ${DIM}boundary roles read -id=<role-id>${NC}"
  echo ""
  echo -e "${YELLOW}4.${NC} List all principals in role:"
  echo -e "   ${DIM}boundary roles read -id=<role-id> -format=json | jq '.item.principal_ids'${NC}"
  echo ""
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
  log_header "Assign Boundary User Permissions"
  
  echo -e "${BOLD}Configuration:${NC}"
  echo -e "  ${CYAN}•${NC} Users: ${USERS}"
  echo -e "  ${CYAN}•${NC} Role Name: ${ROLE_NAME}"
  echo -e "  ${CYAN}•${NC} Project: ${PROJECT_ID}"
  echo -e "  ${CYAN}•${NC} Target: ${TARGET_ID}"
  echo ""
  
  check_prerequisites
  authenticate_boundary
  
  # Create or get role
  local role_id
  role_id=$(create_or_get_role)
  
  if [[ -z "$role_id" ]]; then
    fail "Failed to create or get role"
  fi
  
  # Add grants to role
  add_grant_to_role "$role_id"
  
  # Assign each user to role
  log_section "Assigning Users to Role"
  IFS=',' read -ra USER_ARRAY <<< "$USERS"
  for username in "${USER_ARRAY[@]}"; do
    # Trim whitespace
    username=$(echo "$username" | xargs)
    assign_user_to_role "$username" "$role_id"
  done
  
  show_summary
}

# Run main function
main "$@"

# Made with Bob