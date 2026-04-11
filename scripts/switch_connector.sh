#!/usr/bin/env bash

set -euo pipefail

VERSION="2.5.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET_FILE="${REPO_ROOT}/backend/connector.js"
BASE_URL="https://raw.githubusercontent.com/raymonepping/zero_trust/refs/heads/main/data"
CONTAINER_NAME="zero_trust_backend"
RUNTIME="auto"
EFFECTIVE_RUNTIME=""

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
  [agent-dynamic]="Vault Agent backed dynamic credentials — Phase 2b"
  [approle]="AppRole login → scoped token → static KV credentials — Phase 3a"
  [approle-dynamic]="AppRole login → scoped token → dynamic DB credentials — Phase 3b (full zero trust)"
  [approle-rotation]="AppRole + dynamic DB credentials + proactive rotation at 75% TTL — Phase 4"
  [jwt-rotation]="Keycloak JWT → Vault token → dynamic DB credentials + proactive rotation — Phase 5"
  [jwt-roles]="Keycloak JWT → Vault token → role-scoped dynamic DB credentials + rotation — Phase 6 (most secure)"
  [jwt-ciba]="Keycloak JWT → Vault role-scoped credentials + CIBA-gated write credentials — Phase 7"
)

VALID_TYPES=(wired env vault dynamic agent-dynamic approle approle-dynamic approle-rotation jwt-rotation jwt-roles jwt-ciba)

is_valid_type() {
  local t="$1"
  for v in "${VALID_TYPES[@]}"; do [[ "$v" == "$t" ]] && return 0; done
  return 1
}

detect_runtime() {
  if [[ -n "${CONTAINER_RUNTIME:-}" ]]; then
    case "${CONTAINER_RUNTIME}" in
      docker|podman)
        EFFECTIVE_RUNTIME="${CONTAINER_RUNTIME}"
        return 0
        ;;
    esac
  fi

  if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    EFFECTIVE_RUNTIME="podman"
    return 0
  fi

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    EFFECTIVE_RUNTIME="docker"
    return 0
  fi

  if command -v podman >/dev/null 2>&1; then
    EFFECTIVE_RUNTIME="podman"
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    EFFECTIVE_RUNTIME="docker"
    return 0
  fi

  err "Unable to detect a supported container runtime. Install/start Docker or Podman, or pass --runtime."
  exit 1
}

resolve_runtime() {
  case "${RUNTIME}" in
    auto)
      detect_runtime
      ;;
    docker|podman)
      EFFECTIVE_RUNTIME="${RUNTIME}"
      ;;
    *)
      err "Unsupported runtime '${RUNTIME}'. Use docker, podman, or auto."
      exit 1
      ;;
  esac
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

${C_BOLD}OPTIONS${C_RESET}
  ${C_YELLOW}--runtime${C_RESET} ${C_CYAN}<docker|podman|auto>${C_RESET}  Runtime used for backend restart ${C_DIM}(default: auto)${C_RESET}

${C_BOLD}CONNECTOR TYPES${C_RESET}"

  for t in "${VALID_TYPES[@]}"; do
    printf "  ${C_YELLOW}%-17s${C_RESET} %s\n" "$t" "${CONNECTOR_DESC[$t]}"
  done

  echo -e "
${C_BOLD}EXAMPLES${C_RESET}
  ${C_DIM}# Start from scratch — hardcoded credentials${C_RESET}
  ${C_YELLOW}./switch_connector.sh --replace-with wired${C_RESET}

  ${C_DIM}# Restart backend explicitly with Podman${C_RESET}
  ${C_YELLOW}./switch_connector.sh --runtime podman --replace-with wired${C_RESET}

  ${C_DIM}# Move to environment variables${C_RESET}
  ${C_YELLOW}./switch_connector.sh --replace-with env${C_RESET}

  ${C_DIM}# Enable Vault KV static secrets${C_RESET}
  ${C_YELLOW}./switch_connector.sh --replace-with vault${C_RESET}

  ${C_DIM}# Enable Vault dynamic database credentials${C_RESET}
  ${C_YELLOW}./switch_connector.sh --replace-with dynamic${C_RESET}

  ${C_DIM}# Enable Vault Agent backed dynamic credentials${C_RESET}
  ${C_YELLOW}./switch_connector.sh --replace-with agent-dynamic${C_RESET}

  ${C_DIM}# AppRole + dynamic creds + proactive rotation (Phase 4)${C_RESET}
  ${C_YELLOW}./switch_connector.sh --replace-with approle-rotation${C_RESET}

  ${C_DIM}# Keycloak JWT → Vault → dynamic creds + rotation (Phase 5)${C_RESET}
  ${C_YELLOW}./switch_connector.sh --replace-with jwt-rotation${C_RESET}

  ${C_DIM}# Keycloak JWT → Vault → role-scoped dynamic creds + rotation (Phase 6 — most secure)${C_RESET}
  ${C_YELLOW}./switch_connector.sh --replace-with jwt-roles${C_RESET}

  ${C_DIM}# Final phase: role-scoped reads + CIBA-approved write credentials (Phase 7)${C_RESET}
  ${C_YELLOW}./switch_connector.sh --replace-with jwt-ciba${C_RESET}

${C_BOLD}PREREQUISITES${C_RESET}
  ${C_DIM}•${C_RESET} Docker or Podman with Compose running
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
    printf "  ${C_YELLOW}%-17s${C_RESET} %s\n" "$t" "${CONNECTOR_DESC[$t]}"
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
  if grep -q 'support-write\|getWriteCredentials' "${TARGET_FILE}" 2>/dev/null; then
    detected="jwt-ciba"
  elif grep -q 'Vault Agent file-watch mode\|VAULT_AGENT_CREDS_FILE' "${TARGET_FILE}" 2>/dev/null; then
    detected="agent-dynamic"
  elif grep -q '"vault-jwt-dynamic"\|'"'"'vault-jwt-dynamic'"'" "${TARGET_FILE}" 2>/dev/null \
     && grep -q 'resolveVaultRole\|VAULT_ROLE_MAP' "${TARGET_FILE}" 2>/dev/null; then
    detected="jwt-roles"
  elif grep -q '"vault-jwt-dynamic"\|'"'"'vault-jwt-dynamic'"'" "${TARGET_FILE}" 2>/dev/null; then
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
  local local_file="${REPO_ROOT}/data/connector.${mode}.js"

  if [[ -f "${local_file}" ]]; then
    info "Using local ${C_YELLOW}${mode}${C_RESET} connector..."
    dim "  ${local_file}"
    cp "${local_file}" "${TARGET_FILE}"
  else
    info "Fetching ${C_YELLOW}${mode}${C_RESET} connector from GitHub..."
    dim "  ${url}"

    if ! curl -fsSL "${url}" -o "${TARGET_FILE}"; then
      err "Failed to fetch connector — check the URL or your network connection"
      exit 1
    fi
  fi

  echo
  ok "connector.js replaced with ${C_YELLOW}${mode}${C_RESET}"
  dim "  Target : ${TARGET_FILE}"
  dim "  Source : ${CONNECTOR_DESC[$mode]}"

  echo
  dim "  Checksum: $(md5sum "${TARGET_FILE}" | awk '{print $1}')"

  echo
  resolve_runtime
  info "Restarting backend container ${C_CYAN}${CONTAINER_NAME}${C_RESET} with ${C_CYAN}${EFFECTIVE_RUNTIME}${C_RESET} compose..."

  if ! command -v "${EFFECTIVE_RUNTIME}" >/dev/null 2>&1; then
    err "${EFFECTIVE_RUNTIME} CLI is not installed or not on PATH."
    exit 1
  fi

  if ! (cd "${REPO_ROOT}" && "${EFFECTIVE_RUNTIME}" compose restart backend) 2>/dev/null; then
    err "${EFFECTIVE_RUNTIME} compose restart failed — is the stack running?"
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

COMMAND=""
COMMAND_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)
      RUNTIME="${2:-}"
      [[ -z "${RUNTIME}" ]] && { err "Missing runtime value. Use docker, podman, or auto."; exit 1; }
      shift 2
      ;;
    --replace-with)
      [[ -n "${COMMAND}" ]] && { err "Only one command can be used at a time."; exit 1; }
      COMMAND="replace"
      COMMAND_ARG="${2:-}"
      [[ -z "${COMMAND_ARG}" ]] && { err "Missing connector type. Run --list to see options."; exit 1; }
      shift 2
      ;;
    --list)
      [[ -n "${COMMAND}" ]] && { err "Only one command can be used at a time."; exit 1; }
      COMMAND="list"
      shift
      ;;
    --current)
      [[ -n "${COMMAND}" ]] && { err "Only one command can be used at a time."; exit 1; }
      COMMAND="current"
      shift
      ;;
    --help)
      [[ -n "${COMMAND}" ]] && { err "Only one command can be used at a time."; exit 1; }
      COMMAND="help"
      shift
      ;;
    --version)
      [[ -n "${COMMAND}" ]] && { err "Only one command can be used at a time."; exit 1; }
      COMMAND="version"
      shift
      ;;
    *)
      err "Unknown option: $1"
      echo -e "Run ${C_YELLOW}./switch_connector.sh --help${C_RESET} for usage."
      exit 1
      ;;
  esac
done

case "${COMMAND}" in
  replace) replace_connector "${COMMAND_ARG}" ;;
  list)    list_versions ;;
  current) show_current ;;
  help)    show_help ;;
  version) show_version ;;
  *)
    err "No command provided. Run --help for usage."
    exit 1
    ;;
esac
