#!/usr/bin/env bash

set -euo pipefail

VERSION="2.3.0"

TARGET_FILE="./backend/connector.js"
BASE_URL="https://raw.githubusercontent.com/raymonepping/zero_trust/refs/heads/main/data"
CONTAINER_NAME="zero_trust_backend"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET="\033[0m"
  C_BOLD="\033[1m"
  C_DIM="\033[2m"
  C_YELLOW="\033[33m"
  C_CYAN="\033[36m"
  C_GREEN="\033[32m"
  C_RED="\033[31m"
  C_ORANGE="\033[38;5;214m"
else
  C_RESET="" C_BOLD="" C_DIM="" C_YELLOW="" C_CYAN="" C_GREEN="" C_RED="" C_ORANGE=""
fi

ok()   { echo -e "${C_GREEN}✔${C_RESET} $*"; }
err()  { echo -e "${C_RED}✖ $*${C_RESET}" >&2; }
info() { echo -e "${C_CYAN}→${C_RESET} $*"; }
dim()  { echo -e "${C_DIM}$*${C_RESET}"; }

# ---------------------------------------------------------------------------
# Connector metadata
# ---------------------------------------------------------------------------
declare -A CONNECTOR_DESC=(
  [wired]="Hardcoded credentials in code — Phase 0 starting point"
  [env]="Credentials from environment variables — Phase 0 / no Vault"
  [vault]="Static credentials from Vault KV v2 — Phase 1"
  [dynamic]="Short-lived credentials from Vault database engine — Phase 2"
  [approle]="AppRole login → scoped token → static KV credentials — Phase 3a"
  [approle-dynamic]="AppRole login → scoped token → dynamic DB credentials — Phase 3b (full zero trust)"
  [approle-rotation]="AppRole + dynamic DB credentials + proactive rotation at 75% TTL — Phase 4"
  [jwt-rotation]="Keycloak JWT → Vault token → dynamic DB credentials + proactive rotation — Phase 5 (most secure)"
)

VALID_TYPES=(wired env vault dynamic approle approle-dynamic approle-rotation jwt-rotation)

is_valid_type() {
  local t="$1"
  for v in "${VALID_TYPES[@]}"; do [[ "$v" == "$t" ]] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
show_help() {
  echo -e "
${C_BOLD}${C_ORANGE}switch_connector.sh${C_RESET} ${C_DIM}v${VERSION}${C_RESET}

${C_BOLD}DESCRIPTION${C_RESET}
  Swaps ${C_CYAN}backend/connector.js${C_RESET} with a pre-built version fetched from GitHub,
  then restarts the backend container so the change takes effect immediately.

  This is the core workshop mechanic — each connector type represents a
  different credential strategy, from hardcoded secrets to dynamic Vault leases.

${C_BOLD}USAGE${C_RESET}
  ${C_YELLOW}./switch_connector.sh${C_RESET} ${C_CYAN}<command> [options]${C_RESET}

${C_BOLD}COMMANDS${C_RESET}
  ${C_YELLOW}--replace-with${C_RESET} ${C_CYAN}<type>${C_RESET}    Replace connector.js with the given type and restart backend
  ${C_YELLOW}--list${C_RESET}                    Show all available connector types with descriptions
  ${C_YELLOW}--current${C_RESET}                 Show the active connector type (detected by source header)
  ${C_YELLOW}--help${C_RESET}                    Show this help message
  ${C_YELLOW}--version${C_RESET}                 Show script version

${C_BOLD}CONNECTOR TYPES${C_RESET}"

  for t in "${VALID_TYPES[@]}"; do
    printf "  ${C_YELLOW}%-12s${C_RESET} %s\n" "$t" "${CONNECTOR_DESC[$t]}"
  done

  echo -e "
${C_BOLD}EXAMPLES${C_RESET}
  ${C_DIM}# Start from scratch — hardcoded credentials${C_RESET}
  ${C_YELLOW}./switch_connector.sh --replace-with wired${C_RESET}

  ${C_DIM}# Move to environment variables${C_RESET}
  ${C_YELLOW}./switch_connector.sh --replace-with env${C_RESET}

  ${C_DIM}# Enable Vault KV static secrets${C_RESET}
  ${C_YELLOW}./switch_connector.sh --replace-with vault${C_RESET}

  ${C_DIM}# Enable Vault dynamic database credentials${C_RESET}
  ${C_YELLOW}./switch_connector.sh --replace-with dynamic${C_RESET}

  ${C_DIM}# AppRole + dynamic creds + proactive rotation (Phase 4)${C_RESET}
  ${C_YELLOW}./switch_connector.sh --replace-with approle-rotation${C_RESET}

  ${C_DIM}# Keycloak JWT → Vault → dynamic creds + rotation (Phase 5 — most secure)${C_RESET}
  ${C_YELLOW}./switch_connector.sh --replace-with jwt-rotation${C_RESET}

${C_BOLD}PREREQUISITES${C_RESET}
  ${C_DIM}•${C_RESET} Docker / Podman with Compose running
  ${C_DIM}•${C_RESET} Container named ${C_CYAN}${CONTAINER_NAME}${C_RESET} must be up
  ${C_DIM}•${C_RESET} curl available on PATH
  ${C_DIM}•${C_RESET} For vault/dynamic: Vault must be unsealed and configured

${C_BOLD}VAULT DYNAMIC SETUP${C_RESET}
  ${C_DIM}vault secrets enable database
  vault write database/config/postgres \\
    plugin_name=postgresql-database-plugin \\
    allowed_roles=\"app-role\" \\
    connection_url=\"postgresql://{{username}}:{{password}}@db:5432/appdb?sslmode=disable\" \\
    username=\"appuser\" password=\"apppassword\"
  vault write database/roles/app-role \\
    db_name=postgres \\
    creation_statements=\"CREATE ROLE \\\"{{name}}\\\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \\\"{{name}}\\\";\" \\
    default_ttl=\"1h\" max_ttl=\"24h\"${C_RESET}
"
}

show_version() {
  echo -e "${C_BOLD}switch_connector.sh${C_RESET} v${VERSION}"
}

list_versions() {
  echo -e "\n${C_BOLD}Available connector types:${C_RESET}\n"
  for t in "${VALID_TYPES[@]}"; do
    printf "  ${C_YELLOW}%-12s${C_RESET} %s\n" "$t" "${CONNECTOR_DESC[$t]}"
  done
  echo
}

show_current() {
  if [[ ! -f "${TARGET_FILE}" ]]; then
    err "connector.js not found at ${TARGET_FILE}"
    exit 1
  fi

  # Detect type by matching the unique source: value each connector exports.
  # approle-rotation shares the vault-approle-dynamic source string but also
  # exports startAutoRenewal — check for that first to distinguish the two.
  local detected="unknown"
  if grep -q '"vault-jwt-dynamic"\|'"'"'vault-jwt-dynamic'"'" "${TARGET_FILE}" 2>/dev/null; then
    detected="jwt-rotation"
  elif grep -q '"vault-approle-dynamic"\|'"'"'vault-approle-dynamic'"'" "${TARGET_FILE}" 2>/dev/null \
     && grep -q 'startAutoRenewal' "${TARGET_FILE}" 2>/dev/null; then
    detected="approle-rotation"
  elif grep -q '"vault-approle-dynamic"\|'"'"'vault-approle-dynamic'"'" "${TARGET_FILE}" 2>/dev/null; then
    detected="approle-dynamic"
  elif grep -q '"vault-approle"\|'"'"'vault-approle'"'" "${TARGET_FILE}" 2>/dev/null; then
    detected="approle"
  elif grep -q '"vault-dynamic"\|'"'"'vault-dynamic'"'" "${TARGET_FILE}" 2>/dev/null; then
    detected="dynamic"
  elif grep -q '"vault-kv"\|'"'"'vault-kv'"'" "${TARGET_FILE}" 2>/dev/null; then
    detected="vault"
  elif grep -q '"env-file"\|'"'"'env-file'"'" "${TARGET_FILE}" 2>/dev/null; then
    detected="env"
  elif grep -q '"static-config"\|'"'"'static-config'"'" "${TARGET_FILE}" 2>/dev/null; then
    detected="wired"
  fi

  echo -e "\n${C_BOLD}Active connector:${C_RESET} ${C_YELLOW}${detected}${C_RESET}"
  echo -e "${C_DIM}${CONNECTOR_DESC[$detected]:-}${C_RESET}"
  echo -e "\n${C_BOLD}Checksum:${C_RESET}"
  md5sum "${TARGET_FILE}"
  echo
}

replace_connector() {
  local mode="$1"

  if ! is_valid_type "${mode}"; then
    err "Unknown type '${mode}'. Valid types: ${VALID_TYPES[*]}"
    exit 1
  fi

  local url="${BASE_URL}/connector.${mode}.js"

  info "Fetching ${C_YELLOW}${mode}${C_RESET} connector from GitHub..."
  dim "  ${url}"

  if ! curl -fsSL "${url}" -o "${TARGET_FILE}"; then
    err "Failed to fetch connector — check the URL or your network connection"
    exit 1
  fi

  echo
  ok "connector.js replaced with ${C_YELLOW}${mode}${C_RESET}"
  dim "  Target : ${TARGET_FILE}"
  dim "  Source : ${CONNECTOR_DESC[$mode]}"

  echo
  dim "  Checksum: $(md5sum "${TARGET_FILE}" | awk '{print $1}')"

  echo
  info "Restarting backend container ${C_CYAN}${CONTAINER_NAME}${C_RESET}..."

  if ! docker compose restart backend 2>/dev/null; then
    err "docker compose restart failed — is the stack running?"
    exit 1
  fi

  echo
  ok "Backend restarted — connector is live"
  echo
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
  show_help
  exit 1
fi

case "$1" in
  --replace-with)
    [[ -z "${2:-}" ]] && { err "Missing connector type. Run --list to see options."; exit 1; }
    replace_connector "$2"
    ;;
  --list)    list_versions ;;
  --current) show_current ;;
  --help)    show_help ;;
  --version) show_version ;;
  *)
    err "Unknown option: $1"
    echo -e "Run ${C_YELLOW}./switch_connector.sh --help${C_RESET} for usage."
    exit 1
    ;;
esac
