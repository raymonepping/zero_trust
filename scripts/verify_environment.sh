#!/usr/bin/env bash
# =============================================================================
# verify_environment.sh
# =============================================================================
# Wrapper script that orchestrates all verification scripts for the Zero Trust
# Workshop environment. Executes verification scripts in logical order and
# provides a comprehensive summary of the environment health.
#
# Usage:
#   verify_environment.sh [OPTIONS]
#
# Options:
#   --runtime <docker|podman>    Container runtime to verify (default: auto)
#   --skip <service>             Skip specific verification (comma-separated)
#   --stop-on-error              Stop at first failure
#   --verbose                    Show detailed output from each script
#   --quiet                      Only show summary
#   --json                       Output machine-readable JSON summary
#   --report                     Output compact table report
#   --help                       Show this help
#
# Examples:
#   ./scripts/verify_environment.sh
#   ./scripts/verify_environment.sh --runtime docker --verbose
#   ./scripts/verify_environment.sh --skip vault,keycloak
#   ./scripts/verify_environment.sh --json > environment_status.json
#
# Author : Raymon Epping
# Version: 1.0.0
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# GLOBALS
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERIFICATION_ORDER=(
  "container_runtime:verify_container_runtime.sh:Verifying Container Runtime"
  "postgresql:verify_postgresql.sh:Verifying PostgreSQL"
  "ldap:verify_ldap.sh:Verifying LDAP"
  "keycloak:verify_keycloak.sh:Verifying Keycloak"
  "vault:verify_vault.sh:Verifying Vault"
)

# Configuration
RUNTIME="auto"
EFFECTIVE_RUNTIME=""
SKIP_SERVICES=""
STOP_ON_ERROR=false
VERBOSE=false
QUIET=false
JSON_OUTPUT=false
REPORT_OUTPUT=false

# Counters
TOTAL_CHECKS=0
PASSED=0
WARNINGS=0
FAILED=0

# Timing
START_TIME=$(date +%s)

# Verification results storage
declare -A VERIFICATION_STATUS
declare -A VERIFICATION_DURATION
declare -A VERIFICATION_EXIT_CODE
declare -A VERIFICATION_WARNINGS
declare -A SKIP_ALIASES=(
  ["runtime"]="container_runtime"
  ["container-runtime"]="container_runtime"
)

# Colors (disabled in JSON mode)
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

usage() {
  cat <<'EOF'
verify_environment.sh v1.1.0

Usage:
  verify_environment.sh [OPTIONS]

Description:
  Wrapper script that orchestrates all verification scripts for the Zero Trust
  Workshop environment. Executes verification scripts in logical order and
  provides a comprehensive summary of the environment health.

Options:
  --runtime <docker|podman|auto>
                               Container runtime to verify (default: auto)
  --skip <service>             Skip specific verification (comma-separated)
                               Valid services: runtime, container_runtime,
                               postgresql, ldap, keycloak, vault
  --stop-on-error              Stop at first failure instead of continuing
  --verbose                    Show detailed output from each script
  --quiet                      Only show summary
  --json                       Output machine-readable JSON summary
  --report                     Output compact table report
  --help                       Show this help

Examples:
  ./scripts/verify_environment.sh
  ./scripts/verify_environment.sh --runtime docker --verbose
  ./scripts/verify_environment.sh --skip vault,keycloak
  ./scripts/verify_environment.sh --json > environment_status.json

Exit Codes:
  0 - All verifications passed
  1 - One or more verifications failed
  2 - Invalid arguments or missing dependencies

EOF
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

  error "Unable to detect a supported runtime. Install or start Docker/Podman, or pass --runtime."
  exit 2
}

info() {
  if [[ "$JSON_OUTPUT" == false && "$QUIET" == false ]]; then
    printf "${CYAN}==> %s${RESET}\n" "$*"
  fi
}

error() {
  if [[ "$JSON_OUTPUT" == false ]]; then
    printf "${RED}ERR %s${RESET}\n" "$*" >&2
  fi
}

warn() {
  if [[ "$JSON_OUTPUT" == false && "$QUIET" == false ]]; then
    printf "${YELLOW}WARN %s${RESET}\n" "$*" >&2
  fi
}

ok() {
  if [[ "$JSON_OUTPUT" == false && "$QUIET" == false ]]; then
    printf "${GREEN}OK  %s${RESET}\n" "$*"
  fi
}

header() {
  if [[ "$JSON_OUTPUT" == false && "$QUIET" == false ]]; then
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${BLUE}║  $1${RESET}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${RESET}"
  fi
}

progress() {
  local current="$1"
  local total="$2"
  local name="$3"
  local status="${4:-}"
  
  if [[ "$JSON_OUTPUT" == false && "$QUIET" == false ]]; then
    printf "[%d/%d] %-40s" "$current" "$total" "$name..."
    if [[ -n "$status" ]]; then
      echo "$status"
    fi
  fi
}

should_skip() {
  local service="$1"
  local normalized="$service"
  if [[ -z "$SKIP_SERVICES" ]]; then
    return 1
  fi

  IFS=',' read -ra SKIP_ARRAY <<< "$SKIP_SERVICES"
  for skip in "${SKIP_ARRAY[@]}"; do
    skip="${skip//[[:space:]]/}"
    normalized="${SKIP_ALIASES[$skip]:-$skip}"
    if [[ "$normalized" == "$service" ]]; then
      return 0
    fi
  done
  return 1
}

validate_skip_services() {
  local valid=(
    "container_runtime"
    "postgresql"
    "ldap"
    "keycloak"
    "vault"
  )
  local invalid=()
  local skip normalized known

  [[ -z "$SKIP_SERVICES" ]] && return 0

  IFS=',' read -ra SKIP_ARRAY <<< "$SKIP_SERVICES"
  for skip in "${SKIP_ARRAY[@]}"; do
    skip="${skip//[[:space:]]/}"
    [[ -z "$skip" ]] && continue
    normalized="${SKIP_ALIASES[$skip]:-$skip}"
    known=false
    for valid_name in "${valid[@]}"; do
      if [[ "$normalized" == "$valid_name" ]]; then
        known=true
        break
      fi
    done
    if [[ "$known" == false ]]; then
      invalid+=("$skip")
    fi
  done

  if [[ ${#invalid[@]} -gt 0 ]]; then
    error "Invalid service name(s) for --skip: ${invalid[*]}"
    exit 2
  fi
}

format_duration() {
  local seconds="$1"
  printf "%.1fs" "$seconds"
}

get_status_symbol() {
  local status="$1"
  case "$status" in
    pass) echo -e "${GREEN}✔ PASS${RESET}" ;;
    warn) echo -e "${YELLOW}⚠ WARN${RESET}" ;;
    fail) echo -e "${RED}✖ FAIL${RESET}" ;;
    skip) echo -e "${DIM}○ SKIP${RESET}" ;;
    *) echo "?" ;;
  esac
}

strip_ansi() {
  sed $'s/\x1B\\[[0-9;]*[[:alpha:]]//g'
}

display_name_for() {
  local name="$1"
  case "$name" in
    container_runtime) printf '%s' "Container Runtime" ;;
    postgresql) printf '%s' "PostgreSQL" ;;
    ldap) printf '%s' "LDAP" ;;
    keycloak) printf '%s' "Keycloak" ;;
    vault) printf '%s' "Vault" ;;
    *) printf '%s' "$name" ;;
  esac
}

report_status_label() {
  local status="$1"
  case "$status" in
    pass) printf '%s' "PASS" ;;
    warn) printf '%s' "WARN" ;;
    fail) printf '%s' "FAIL" ;;
    skip) printf '%s' "SKIP" ;;
    *) printf '%s' "UNKNOWN" ;;
  esac
}

report_status_color() {
  local status="$1"
  case "$status" in
    pass) printf '%b' "$GREEN" ;;
    warn) printf '%b' "$YELLOW" ;;
    fail) printf '%b' "$RED" ;;
    skip) printf '%b' "$DIM" ;;
    *) printf '%b' "$RESET" ;;
  esac
}

# =============================================================================
# VERIFICATION EXECUTION
# =============================================================================

run_verification() {
  local name="$1"
  local script="$2"
  local display_name="$3"
  local total="${#VERIFICATION_ORDER[@]}"
  
  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  
  # Check if should skip
  if should_skip "$name"; then
    VERIFICATION_STATUS["$name"]="skip"
    VERIFICATION_DURATION["$name"]=0
    VERIFICATION_EXIT_CODE["$name"]=0
    VERIFICATION_WARNINGS["$name"]=""
    progress "$TOTAL_CHECKS" "$total" "$display_name" "$(get_status_symbol skip) (0.0s)"
    return 0
  fi
  
  progress "$TOTAL_CHECKS" "$total" "$display_name"
  
  # Prepare script path
  local script_path="${SCRIPT_DIR}/${script}"
  
  if [[ ! -f "$script_path" ]]; then
    error "Verification script not found: $script_path"
    VERIFICATION_STATUS["$name"]="fail"
    VERIFICATION_DURATION["$name"]=0
    VERIFICATION_EXIT_CODE["$name"]=127
    VERIFICATION_WARNINGS["$name"]="Script not found"
    FAILED=$((FAILED + 1))
    printf " %s (0.0s)\n" "$(get_status_symbol fail)"
    return 1
  fi
  
  # Make script executable if needed
  chmod +x "$script_path" 2>/dev/null || true
  
  # Prepare arguments
  local args=()
  args+=("--runtime" "$EFFECTIVE_RUNTIME")
  
  # Execute verification script
  local start
  start=$(date +%s)
  local output
  local exit_code=0
  
  if [[ "$VERBOSE" == true ]]; then
    if [[ "$JSON_OUTPUT" == false ]]; then
      echo ""
    fi
    output=$("$script_path" "${args[@]}" 2>&1 | tee /dev/stderr) || exit_code=$?
  else
    output=$("$script_path" "${args[@]}" 2>&1) || exit_code=$?
  fi
  
  local end
  end=$(date +%s)
  local duration=$((end - start))
  
  # Store results
  VERIFICATION_EXIT_CODE["$name"]=$exit_code
  VERIFICATION_DURATION["$name"]=$duration
  
  # Analyze output for warnings (strip ANSI codes first)
  local warnings=""
  if [[ -n "$output" ]]; then
    local clean_output
    clean_output=$(printf '%s\n' "$output" | strip_ansi)
    warnings=$(printf '%s\n' "$clean_output" | grep -E '(^|[[:space:]])WARN([[:space:]]|$)' | head -n 3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '\n' ';' || true)
    warnings="${warnings%;}"
  fi
  VERIFICATION_WARNINGS["$name"]="$warnings"
  
  # Determine status
  local status="pass"
  if [[ $exit_code -ne 0 ]]; then
    status="fail"
    FAILED=$((FAILED + 1))
  elif [[ -n "$warnings" ]]; then
    status="warn"
    WARNINGS=$((WARNINGS + 1))
  else
    PASSED=$((PASSED + 1))
  fi
  
  VERIFICATION_STATUS["$name"]="$status"
  
  # Show result
  if [[ "$VERBOSE" == false && "$JSON_OUTPUT" == false && "$QUIET" == false ]]; then
    printf " %s (%s)\n" "$(get_status_symbol "$status")" "$(format_duration "$duration")"
  fi
  
  # Stop on error if requested
  if [[ "$STOP_ON_ERROR" == true && $exit_code -ne 0 ]]; then
    error "Verification failed: $display_name (exit code: $exit_code)"
    return 1
  fi
  
  return 0
}

# =============================================================================
# SUMMARY GENERATION
# =============================================================================

generate_json_summary() {
  local end_time
  end_time=$(date +%s)
  local total_time=$((end_time - START_TIME))
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  # Determine overall status
  local overall_status="ready"
  if [[ $FAILED -gt 0 ]]; then
    overall_status="failed"
  elif [[ $WARNINGS -gt 0 ]]; then
    overall_status="ready_with_warnings"
  fi
  
  # Calculate health score
  local health_score=0
  if [[ $TOTAL_CHECKS -gt 0 ]]; then
    health_score=$(( (PASSED * 100 + WARNINGS * 50) / TOTAL_CHECKS ))
  fi
  
  # Build JSON
  cat <<EOF
{
  "timestamp": "$timestamp",
  "runtime": "$EFFECTIVE_RUNTIME",
  "total_time_seconds": $total_time,
  "overall_status": "$overall_status",
  "health_score": $health_score,
  "verifications": [
EOF

  local first=true
  local entry script display_name name
  for entry in "${VERIFICATION_ORDER[@]}"; do
    IFS=':' read -r name script display_name <<< "$entry"
    if [[ "$first" == true ]]; then
      first=false
    else
      echo ","
    fi
    
    local status="${VERIFICATION_STATUS[$name]:-unknown}"
    local duration="${VERIFICATION_DURATION[$name]:-0}"
    local exit_code="${VERIFICATION_EXIT_CODE[$name]:-0}"
    local warnings="${VERIFICATION_WARNINGS[$name]:-}"
    
    # Escape warnings for JSON
    if [[ -n "$warnings" ]]; then
      # Split on semicolon, escape quotes, and build JSON array
      local warning_array=""
      IFS=';' read -ra WARN_PARTS <<< "$warnings"
      local first_warn=true
      local warning_item
      for warning_item in "${WARN_PARTS[@]}"; do
        warning_item="$(printf '%s' "$warning_item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [[ -n "$warning_item" ]]; then
          warning_item=$(printf '%s' "$warning_item" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
          if [[ "$first_warn" == true ]]; then
            warning_array="\"$warning_item\""
            first_warn=false
          else
            warning_array="$warning_array, \"$warning_item\""
          fi
        fi
      done
      warnings="$warning_array"
    else
      warnings=""
    fi
    
    cat <<EOF
    {
      "name": "$name",
      "status": "$status",
      "duration_seconds": $duration,
      "exit_code": $exit_code,
      "warnings": [$warnings]
    }
EOF
  done

  cat <<EOF

  ],
  "summary": {
    "total_checks": $TOTAL_CHECKS,
    "passed": $PASSED,
    "warnings": $WARNINGS,
    "failed": $FAILED
  }
}
EOF
}

generate_human_summary() {
  local end_time
  end_time=$(date +%s)
  local total_time=$((end_time - START_TIME))
  
  echo ""
  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${BLUE}║  VERIFICATION SUMMARY                                        ║${RESET}"
  echo -e "${BOLD}${BLUE}╠══════════════════════════════════════════════════════════════╣${RESET}"
  
  # Show each verification result
  local entry script display_name name
  for entry in "${VERIFICATION_ORDER[@]}"; do
    IFS=':' read -r name script display_name <<< "$entry"
    local status="${VERIFICATION_STATUS[$name]:-unknown}"
    local duration="${VERIFICATION_DURATION[$name]:-0}"
    
    printf "${BOLD}${BLUE}║${RESET}  %-20s %s" "$display_name" "$(get_status_symbol "$status")"
    
    # Add warning details if present
    local warnings="${VERIFICATION_WARNINGS[$name]:-}"
    if [[ -n "$warnings" && "$status" == "warn" ]]; then
      printf "%s" " ${DIM}(warnings detected)${RESET}"
    fi
    
    # Pad to align
    local padding=$((40 - ${#display_name}))
    printf "%${padding}s${BOLD}${BLUE}║${RESET}\n" ""
  done
  
  echo -e "${BOLD}${BLUE}╠══════════════════════════════════════════════════════════════╣${RESET}"
  
  # Overall status
  local overall_status="READY"
  local status_color="$GREEN"
  if [[ $FAILED -gt 0 ]]; then
    overall_status="FAILED"
    status_color="$RED"
  elif [[ $WARNINGS -gt 0 ]]; then
    overall_status="READY WITH WARNINGS"
    status_color="$YELLOW"
  fi
  
  # Calculate health score
  local health_score=0
  if [[ $TOTAL_CHECKS -gt 0 ]]; then
    health_score=$(( (PASSED * 100 + WARNINGS * 50) / TOTAL_CHECKS ))
  fi
  
  echo -e "${BOLD}${BLUE}║${RESET}  Overall Status: ${status_color}${overall_status}${RESET}${BOLD}${BLUE}                                   ║${RESET}"
  echo -e "${BOLD}${BLUE}║${RESET}  Health Score: ${health_score}% (${PASSED}/${TOTAL_CHECKS} passed, ${WARNINGS} warning(s), ${FAILED} failed)${BOLD}${BLUE}    ║${RESET}"
  echo -e "${BOLD}${BLUE}║${RESET}  Total Time: $(format_duration "$total_time")${BOLD}${BLUE}                                              ║${RESET}"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${RESET}"
  
  # Additional messages
  if [[ $FAILED -gt 0 ]]; then
    echo ""
    error "One or more verifications failed. Review output above for details."
  elif [[ $WARNINGS -gt 0 ]]; then
    echo ""
    warn "Warnings detected. Review output above for details."
  else
    echo ""
    ok "All verifications passed successfully!"
  fi
}

generate_report_summary() {
  local end_time
  end_time=$(date +%s)
  local total_time=$((end_time - START_TIME))
  local overall_status="READY"
  local overall_color="$GREEN"

  if [[ $FAILED -gt 0 ]]; then
    overall_status="FAILED"
    overall_color="$RED"
  elif [[ $WARNINGS -gt 0 ]]; then
    overall_status="READY WITH WARNINGS"
    overall_color="$YELLOW"
  fi

  local health_score=0
  if [[ $TOTAL_CHECKS -gt 0 ]]; then
    health_score=$(( (PASSED * 100 + WARNINGS * 50) / TOTAL_CHECKS ))
  fi

  local health_color="$GREEN"
  local health_display="${health_score}%"
  local executed_checks=$((PASSED + WARNINGS + FAILED))
  if [[ $executed_checks -eq 0 ]]; then
    health_color="$DIM"
    health_display="N/A"
  elif [[ $health_score -lt 100 && $health_score -ge 70 ]]; then
    health_color="$YELLOW"
  elif [[ $health_score -lt 70 ]]; then
    health_color="$RED"
  fi

  printf '%bEnvironment Verification Report%b\n' "$BOLD$BLUE" "$RESET"
  printf 'Runtime: %b%s%b\n' "$CYAN" "$EFFECTIVE_RUNTIME" "$RESET"
  printf 'Overall: %b%s%b\n' "$overall_color$BOLD" "$overall_status" "$RESET"
  printf 'Health : %b%s%b\n' "$health_color$BOLD" "$health_display" "$RESET"
  printf 'Time   : %b%s%b\n' "$CYAN" "$(format_duration "$total_time")" "$RESET"
  printf '\n'
  printf '%b%-20s %-8s %-10s %-6s %s%b\n' "$BOLD$BLUE" "Service" "Status" "Duration" "Exit" "Warnings" "$RESET"
  printf '%b%-20s %-8s %-10s %-6s %s%b\n' "$BLUE" "--------------------" "--------" "----------" "------" "--------" "$RESET"

  local entry script display_name name
  for entry in "${VERIFICATION_ORDER[@]}"; do
    IFS=':' read -r name script display_name <<< "$entry"
    local status="${VERIFICATION_STATUS[$name]:-unknown}"
    local duration="${VERIFICATION_DURATION[$name]:-0}"
    local exit_code="${VERIFICATION_EXIT_CODE[$name]:-0}"
    local warnings="${VERIFICATION_WARNINGS[$name]:-}"
    local warning_count=0

    if [[ -n "$warnings" ]]; then
      IFS=';' read -ra WARN_PARTS <<< "$warnings"
      local warning_item
      for warning_item in "${WARN_PARTS[@]}"; do
        warning_item="${warning_item#"${warning_item%%[![:space:]]*}"}"
        warning_item="${warning_item%"${warning_item##*[![:space:]]}"}"
        [[ -n "$warning_item" ]] && warning_count=$((warning_count + 1))
      done
    fi

    local status_label
    status_label="$(report_status_label "$status")"
    local status_color
    status_color="$(report_status_color "$status")"
    local warning_cell="$warning_count"
    if [[ $warning_count -gt 0 ]]; then
      warning_cell="${YELLOW}${warning_count}${RESET}"
    fi

    printf '%-20s %b%-8s%b %-10s %-6s %b\n' \
      "$(display_name_for "$name")" \
      "$status_color" \
      "$status_label" \
      "$RESET" \
      "$(format_duration "$duration")" \
      "$exit_code" \
      "$warning_cell"
  done

  printf '\n'
  printf 'Checks: %b%d%b total, %b%d%b passed, %b%d%b warnings, %b%d%b failed\n' \
    "$CYAN" "$TOTAL_CHECKS" "$RESET" \
    "$GREEN" "$PASSED" "$RESET" \
    "$YELLOW" "$WARNINGS" "$RESET" \
    "$RED" "$FAILED" "$RESET"
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)
      RUNTIME="${2:-}"
      if [[ -z "$RUNTIME" ]]; then
        error "Missing value for --runtime"
        usage >&2
        exit 2
      fi
      shift 2
      ;;
    --skip)
      SKIP_SERVICES="${2:-}"
      if [[ -z "$SKIP_SERVICES" ]]; then
        error "Missing value for --skip"
        usage >&2
        exit 2
      fi
      shift 2
      ;;
    --stop-on-error)
      STOP_ON_ERROR=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --quiet)
      QUIET=true
      shift
      ;;
    --json)
      JSON_OUTPUT=true
      QUIET=true  # JSON mode implies quiet
      shift
      ;;
    --report)
      REPORT_OUTPUT=true
      QUIET=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown argument: $1"
      usage >&2
      exit 2
      ;;
  esac
done

# Validate runtime
if [[ "$RUNTIME" != "auto" && "$RUNTIME" != "docker" && "$RUNTIME" != "podman" ]]; then
  error "Invalid runtime: $RUNTIME. Use 'auto', 'docker', or 'podman'."
  exit 2
fi

validate_skip_services

if [[ "$RUNTIME" == "auto" ]]; then
  detect_runtime
else
  EFFECTIVE_RUNTIME="$RUNTIME"
fi

if [[ "$JSON_OUTPUT" == true && "$REPORT_OUTPUT" == true ]]; then
  error "Use either --json or --report, not both."
  exit 2
fi

# =============================================================================
# MAIN EXECUTION
# =============================================================================

# Show header
if [[ "$JSON_OUTPUT" == false ]]; then
  header "Zero Trust Workshop - Environment Verification"
  if [[ "$RUNTIME" == "auto" ]]; then
    info "Runtime: auto-detected -> $EFFECTIVE_RUNTIME"
  else
    info "Runtime: $EFFECTIVE_RUNTIME"
  fi
  if [[ -n "$SKIP_SERVICES" ]]; then
    info "Skipping: $SKIP_SERVICES"
  fi
fi

# Run verifications in logical order
for entry in "${VERIFICATION_ORDER[@]}"; do
  IFS=':' read -r name script display_name <<< "$entry"
  run_verification "$name" "$script" "$display_name" || break
done

# Generate summary
if [[ "$JSON_OUTPUT" == true ]]; then
  generate_json_summary
elif [[ "$REPORT_OUTPUT" == true ]]; then
  generate_report_summary
else
  generate_human_summary
fi

# Exit with appropriate code
if [[ $FAILED -gt 0 ]]; then
  exit 1
else
  exit 0
fi
