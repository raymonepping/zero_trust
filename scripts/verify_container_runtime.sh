#!/usr/bin/env bash
# =============================================================================
# verify_container_runtime.sh
# =============================================================================
# Detect, diagnose, and correct container runtime issues for Docker and Podman
# on macOS. Covers binary, daemon, machine state, storage, networking, ports,
# compose, and optional service health checks.
#
# Usage:
#   verify_container_runtime.sh [OPTIONS]
#
# Options:
#   --runtime <docker|podman|auto>   Runtime to verify (default: auto)
#   --fix                            Attempt safe automatic corrections
#   --services                       Check Vault, Nomad, Consul, PostgreSQL
#   --ports                          Deep port conflict scan
#   --verbose                        Show passing checks too
#   --json                           Output machine-readable JSON summary
#   --help                           Show this help
#
# Author : Raymon Epping
# Copilot: Sally (AI)
# Version: 1.0.0
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# GLOBALS
# =============================================================================

SCRIPT_NAME="$(basename "$0")"
VERSION="1.1.0"

RUNTIME="auto"
FIX=false
CHECK_SERVICES=false
CHECK_PORTS=false
VERBOSE=false
JSON_OUTPUT=false

PASS=0
WARN=0
FAIL=0
FIXED=0

DETECTED_RUNTIME=""
DAEMON_OK=false

# Detect macOS date syntax once at startup
if date -j >/dev/null 2>&1; then _DATE_MACOS=1; else _DATE_MACOS=0; fi

# JSON accumulator
JSON_RESULTS=()

# Colors
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# =============================================================================
# HELPERS — OUTPUT
# =============================================================================

header() {
  echo ""
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${BLUE}  $1${RESET}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════${RESET}"
}

section() {
  echo ""
  echo -e "${BOLD}${CYAN}▸ $1${RESET}"
}

pass() {
  local msg="$1"
  local detail="${2:-}"
  PASS=$((PASS + 1))
  if [[ "$VERBOSE" == true ]]; then
    echo -e "  ${GREEN}✔${RESET} ${msg}${detail:+ ${DIM}(${detail})${RESET}}"
  fi
  json_record "pass" "$msg" "$detail"
}

warn() {
  local msg="$1"
  local detail="${2:-}"
  WARN=$((WARN + 1))
  echo -e "  ${YELLOW}⚠${RESET} ${msg}${detail:+ ${DIM}→ ${detail}${RESET}}"
  json_record "warn" "$msg" "$detail"
}

fail() {
  local msg="$1"
  local detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo -e "  ${RED}✘${RESET} ${msg}${detail:+ ${DIM}→ ${detail}${RESET}}"
  json_record "fail" "$msg" "$detail"
}

fixed() {
  local msg="$1"
  local detail="${2:-}"
  FIXED=$((FIXED + 1))
  PASS=$((PASS + 1))
  echo -e "  ${GREEN}⚙${RESET} ${BOLD}FIXED${RESET} ${msg}${detail:+ ${DIM}(${detail})${RESET}}"
  json_record "fixed" "$msg" "$detail"
}

suggest() {
  echo -e "  ${DIM}   ↳ Fix: ${RESET}${1}"
}

info() {
  echo -e "  ${DIM}   ℹ ${1}${RESET}"
}

json_record() {
  local status="$1"
  local msg="$2"
  local detail="${3:-}"
  JSON_RESULTS+=("{\"status\":\"${status}\",\"message\":$(echo "$msg" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read().strip()))'),\"detail\":$(echo "$detail" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read().strip()))')}")
}

# =============================================================================
# HELPERS — DETECTION
# =============================================================================

cmd_exists() {
  command -v "$1" &>/dev/null
}

runtime_cmd() {
  echo "$DETECTED_RUNTIME"
}

compose_cmd() {
  if [[ "$DETECTED_RUNTIME" == "docker" ]]; then
    if docker compose version &>/dev/null 2>&1; then
      echo "docker compose"
    elif cmd_exists docker-compose; then
      echo "docker-compose"
    else
      echo ""
    fi
  else
    if podman compose version &>/dev/null 2>&1; then
      echo "podman compose"
    elif cmd_exists podman-compose; then
      echo "podman-compose"
    else
      echo ""
    fi
  fi
}

macos_check() {
  [[ "$(uname -s)" == "Darwin" ]]
}

# Cross-platform timeout: macOS ships gtimeout (coreutils) not timeout
_timeout() {
  local secs=$1; shift
  if command -v timeout &>/dev/null; then
    timeout "$secs" "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$secs" "$@"
  else
    # Fallback: background process + watcher
    "$@" &
    local pid=$!
    ( sleep "$secs" 2>/dev/null; kill "$pid" 2>/dev/null ) &
    local watcher=$!
    wait "$pid" 2>/dev/null
    local rc=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    return $rc
  fi
}

wait_for_daemon() {
  local rt="$1"
  local attempts=0
  local max=12
  while [[ $attempts -lt $max ]]; do
    if $rt info &>/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    attempts=$((attempts + 1))
  done
  return 1
}

# =============================================================================
# PARSE ARGS
# =============================================================================

usage() {
  cat <<EOF
${BOLD}${SCRIPT_NAME} v${VERSION}${RESET}

Detect, diagnose, and correct container runtime issues on macOS.

${BOLD}USAGE${RESET}
  ${SCRIPT_NAME} [OPTIONS]

${BOLD}OPTIONS${RESET}
  --runtime <docker|podman|auto>   Runtime to verify (default: auto)
  --fix                            Attempt safe automatic corrections
  --services                       Check Vault, Nomad, Consul, PostgreSQL
  --ports                          Deep port conflict scan
  --verbose                        Show all checks including passing ones
  --json                           Output machine-readable JSON summary
  --help                           Show this help

${BOLD}EXAMPLES${RESET}
  ${SCRIPT_NAME} --runtime docker
  ${SCRIPT_NAME} --runtime podman --fix
  ${SCRIPT_NAME} --runtime auto --fix --services --verbose
  ${SCRIPT_NAME} --runtime docker --json
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)
      RUNTIME="${2:-auto}"
      shift 2
      ;;
    --fix)
      FIX=true
      shift
      ;;
    --services)
      CHECK_SERVICES=true
      shift
      ;;
    --ports)
      CHECK_PORTS=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# =============================================================================
# SECTION 1 — RUNTIME DETECTION
# =============================================================================

detect_runtime() {
  header "Runtime Detection"
  section "Identifying available runtimes"

  local docker_ok=false
  local podman_ok=false

  cmd_exists docker && docker_ok=true
  cmd_exists podman && podman_ok=true

  case "$RUNTIME" in
    docker)
      if [[ "$docker_ok" == false ]]; then
        fail "Docker CLI not found on PATH"
        suggest "brew install --cask docker"
        exit 1
      fi
      DETECTED_RUNTIME="docker"
      pass "Docker CLI found" "$(docker --version 2>/dev/null | head -1)"
      ;;
    podman)
      if [[ "$podman_ok" == false ]]; then
        fail "Podman CLI not found on PATH"
        suggest "brew install podman"
        exit 1
      fi
      DETECTED_RUNTIME="podman"
      pass "Podman CLI found" "$(podman --version 2>/dev/null | head -1)"
      ;;
    auto)
      if [[ "$docker_ok" == true && "$podman_ok" == true ]]; then
        # Prefer whichever daemon is currently reachable
        if docker info &>/dev/null 2>&1; then
          DETECTED_RUNTIME="docker"
          pass "Auto-detected: Docker (daemon reachable)" "$(docker --version 2>/dev/null | head -1)"
        elif podman info &>/dev/null 2>&1; then
          DETECTED_RUNTIME="podman"
          pass "Auto-detected: Podman (daemon reachable)" "$(podman --version 2>/dev/null | head -1)"
        else
          warn "Both Docker and Podman found but neither daemon is reachable"
          DETECTED_RUNTIME="docker"
          info "Defaulting to Docker for subsequent checks"
        fi
      elif [[ "$docker_ok" == true ]]; then
        DETECTED_RUNTIME="docker"
        pass "Auto-detected: Docker" "$(docker --version 2>/dev/null | head -1)"
      elif [[ "$podman_ok" == true ]]; then
        DETECTED_RUNTIME="podman"
        pass "Auto-detected: Podman" "$(podman --version 2>/dev/null | head -1)"
      else
        fail "No container runtime found (docker or podman)"
        suggest "brew install --cask docker   # for Docker Desktop"
        suggest "brew install podman          # for Podman"
        exit 1
      fi
      ;;
  esac

  echo ""
  echo -e "  ${BOLD}Runtime: ${CYAN}${DETECTED_RUNTIME}${RESET}"
}

# =============================================================================
# SECTION 2 — BINARY & VERSION CHECKS
# =============================================================================

check_binary() {
  header "Binary & Version"
  local rt="$DETECTED_RUNTIME"

  section "CLI version"
  local version
  version=$($rt --version 2>/dev/null) || { fail "${rt} --version failed"; return; }
  pass "${rt} CLI version" "$version"

  if [[ "$rt" == "docker" ]]; then
    section "Docker context"
    local ctx
    ctx=$(docker context show 2>/dev/null) || ctx="unknown"
    if [[ "$ctx" == "default" || "$ctx" == "desktop-linux" || "$ctx" == "colima" ]]; then
      pass "Docker context" "$ctx"
    else
      warn "Unexpected Docker context" "$ctx — may point to wrong daemon"
    fi

    section "Docker buildx"
    if docker buildx version &>/dev/null 2>&1; then
      pass "docker buildx available" "$(docker buildx version 2>/dev/null | head -1)"
    else
      warn "docker buildx not available" "multi-platform builds unavailable"
      suggest "docker buildx install"
    fi
  fi

  if [[ "$rt" == "podman" ]]; then
    section "Podman remote"
    if podman system connection list &>/dev/null 2>&1; then
      local conns
      conns=$(podman system connection list 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
      if [[ "$conns" -gt 0 ]]; then
        pass "Podman connections defined" "${conns} connection(s)"
      else
        warn "No Podman remote connections defined"
        suggest "podman machine init (if using Podman machine)"
      fi
    fi
  fi
}

# =============================================================================
# SECTION 3 — DAEMON / SOCKET
# =============================================================================

check_daemon() {
  header "Daemon & Socket"
  local rt="$DETECTED_RUNTIME"

  section "Daemon reachability"
  if _timeout 5 $rt info &>/dev/null 2>&1; then
    DAEMON_OK=true
    pass "${rt} daemon is reachable"
  else
    fail "${rt} daemon is NOT reachable"

    if [[ "$rt" == "docker" ]]; then
      if macos_check; then
        if [[ "$FIX" == true ]]; then
          echo -e "  ${YELLOW}  Attempting to start Docker Desktop...${RESET}"
          open -a Docker 2>/dev/null || true
          if wait_for_daemon docker; then
            fixed "Docker Desktop started successfully"
          else
            fail "Docker Desktop did not start within 24 seconds"
            suggest "Open Docker Desktop manually from Applications"
          fi
        else
          suggest "open -a Docker   # start Docker Desktop"
          suggest "Or: colima start  # if using Colima"
        fi
      else
        suggest "sudo systemctl start docker"
      fi
    fi

    if [[ "$rt" == "podman" ]]; then
      if macos_check; then
        local machine_name
        machine_name=$(podman machine list --format '{{.Name}}' 2>/dev/null | head -1) || machine_name=""

        if [[ -z "$machine_name" ]]; then
          fail "No Podman machine found"
          if [[ "$FIX" == true ]]; then
            echo -e "  ${YELLOW}  Initializing and starting default Podman machine...${RESET}"
            podman machine init 2>/dev/null && podman machine start 2>/dev/null && fixed "Podman machine initialized and started" || \
              fail "Failed to init/start Podman machine"
          else
            suggest "podman machine init && podman machine start"
          fi
        else
          local state
          state=$(podman machine list --format '{{.LastUp}}' 2>/dev/null | head -1) || state="unknown"
          fail "Podman machine '${machine_name}' exists but daemon not reachable" "Last state: ${state}"
          if [[ "$FIX" == true ]]; then
            echo -e "  ${YELLOW}  Attempting to start Podman machine '${machine_name}'...${RESET}"
            podman machine start "$machine_name" 2>/dev/null && wait_for_daemon podman && \
              fixed "Podman machine '${machine_name}' started" || \
              fail "Failed to start Podman machine '${machine_name}'"
          else
            suggest "podman machine start ${machine_name}"
          fi
        fi
      else
        suggest "systemctl --user start podman.socket"
      fi
    fi
    return
  fi

  section "Socket path"
  if [[ "$rt" == "docker" ]]; then
    local socket_path="/var/run/docker.sock"
    if [[ -S "$socket_path" ]]; then
      pass "Docker socket exists" "$socket_path"
    else
      # Check for Docker Desktop socket
      local alt_socket="$HOME/.docker/run/docker.sock"
      if [[ -S "$alt_socket" ]]; then
        pass "Docker socket found (Desktop path)" "$alt_socket"
        warn "DOCKER_HOST may need to be set"
        suggest "export DOCKER_HOST=unix://${alt_socket}"
      else
        warn "Docker socket not found at expected paths"
        suggest "Ensure Docker Desktop is running, or set DOCKER_HOST"
      fi
    fi
  fi

  if [[ "$rt" == "podman" ]]; then
    local uid_socket="/run/user/$(id -u)/podman/podman.sock"
    local machine_socket_qemu="$HOME/.local/share/containers/podman/machine/qemu/podman.sock"
    local machine_socket_applehv="$HOME/.local/share/containers/podman/machine/applehv/podman.sock"
    # Podman Desktop (macOS) uses a user-level socket derived from the machine
    local desktop_socket
    desktop_socket=$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null | head -1) || desktop_socket=""

    local found_socket=""
    for s in "$uid_socket" "$machine_socket_qemu" "$machine_socket_applehv" "$desktop_socket"; do
      [[ -z "$s" ]] && continue
      if [[ -S "$s" ]]; then found_socket="$s"; break; fi
    done

    if [[ -n "$found_socket" ]]; then
      pass "Podman socket found" "$found_socket"
    else
      # Daemon is reachable (we passed the info check) — socket is via Podman Desktop
      # and may not be a plain file socket accessible from the host path
      info "Podman socket not at a standard host path (normal with Podman Desktop)"
    fi
  fi

  section "Daemon info"
  local server_version
  if [[ "$rt" == "docker" ]]; then
    server_version=$(_timeout 5 docker info --format '{{.ServerVersion}}' 2>/dev/null) || server_version="unknown"
    local os_type
    os_type=$(_timeout 5 docker info --format '{{.OSType}}' 2>/dev/null) || os_type="unknown"
    local containers_running
    containers_running=$(_timeout 5 docker info --format '{{.ContainersRunning}}' 2>/dev/null) || containers_running="0"
    pass "Docker server version" "$server_version"
    pass "OS type" "$os_type"
    pass "Containers running" "$containers_running"
  else
    server_version=$(_timeout 5 podman info --format '{{.Version.Version}}' 2>/dev/null) || server_version="unknown"
    local containers_running
    containers_running=$(podman ps -q 2>/dev/null | wc -l | tr -d ' ') || containers_running="0"
    pass "Podman version" "$server_version"
    pass "Containers running" "$containers_running"
  fi
}

# =============================================================================
# SECTION 4 — MACHINE STATE (macOS)
# =============================================================================

check_machine_state() {
  if ! macos_check; then return; fi
  header "Machine State (macOS)"
  local rt="$DETECTED_RUNTIME"

  if [[ "$rt" == "docker" ]]; then
    section "Docker Desktop"
    if pgrep -x "Docker" &>/dev/null || pgrep -f "Docker Desktop" &>/dev/null; then
      pass "Docker Desktop process is running"
    else
      warn "Docker Desktop process not detected"
      if [[ "$FIX" == true ]]; then
        open -a Docker 2>/dev/null && fixed "Docker Desktop launched" || warn "Could not launch Docker Desktop"
      else
        suggest "open -a Docker"
      fi
    fi

    section "Colima (alternative)"
    if cmd_exists colima; then
      local colima_status
      colima_status=$(colima status 2>/dev/null | head -1) || colima_status="not running"
      if echo "$colima_status" | grep -qi "running"; then
        pass "Colima is running" "$colima_status"
      else
        info "Colima installed but not running (optional)"
      fi
    else
      info "Colima not installed (optional lightweight alternative)"
    fi
  fi

  if [[ "$rt" == "podman" ]]; then
    section "Podman machine"
    local machines
    machines=$(podman machine list 2>/dev/null) || machines=""

    if [[ -z "$machines" ]] || ! echo "$machines" | grep -v "^NAME" | grep -q "."; then
      fail "No Podman machines configured"
      if [[ "$FIX" == true ]]; then
        echo -e "  ${YELLOW}  Initializing default Podman machine...${RESET}"
        podman machine init 2>/dev/null && podman machine start 2>/dev/null && \
          fixed "Podman machine initialized and started" || \
          fail "Failed to initialize Podman machine"
      else
        suggest "podman machine init"
        suggest "podman machine start"
      fi
      return
    fi

    # Parse machine state using --format to avoid fragile column-index parsing
    while IFS='|' read -r mname mrunning; do
      [[ -z "$mname" ]] && continue
      if [[ "$mrunning" == "true" ]]; then
        pass "Podman machine '${mname}'" "running"
      else
        fail "Podman machine '${mname}' is not running"
        if [[ "$FIX" == true ]]; then
          podman machine start "$mname" 2>/dev/null && \
            fixed "Started Podman machine '${mname}'" || \
            fail "Failed to start Podman machine '${mname}'"
        else
          suggest "podman machine start ${mname}"
        fi
      fi
    done < <(podman machine list --format '{{.Name}}|{{.Running}}' 2>/dev/null | tail -n +2)

    section "Podman machine resources"
    local machine_name
    machine_name=$(podman machine list --format '{{.Name}}' 2>/dev/null | head -1) || machine_name=""
    if [[ -n "$machine_name" ]]; then
      local cpu mem disk
      cpu=$(podman machine inspect "$machine_name" --format '{{.Resources.CPUs}}' 2>/dev/null) || cpu="?"
      mem=$(podman machine inspect "$machine_name" --format '{{.Resources.Memory}}' 2>/dev/null) || mem="?"
      disk=$(podman machine inspect "$machine_name" --format '{{.Resources.DiskSize}}' 2>/dev/null) || disk="?"
      pass "Machine CPUs" "$cpu"
      pass "Machine memory" "${mem} MB"
      pass "Machine disk" "${disk} GB"
    fi
  fi
}

# =============================================================================
# SECTION 5 — BASIC OPERATIONS
# =============================================================================

check_basic_ops() {
  header "Basic Operations"
  local rt="$DETECTED_RUNTIME"

  if [[ "$DAEMON_OK" == false ]]; then
    info "Skipping — daemon not reachable"
    return
  fi

  section "Container list"
  if $rt ps &>/dev/null 2>&1; then
    local count
    count=$($rt ps -q 2>/dev/null | wc -l | tr -d ' ')
    pass "${rt} ps succeeded" "${count} container(s) running"
  else
    fail "${rt} ps failed — daemon may not be fully ready"
    return
  fi

  section "Image list"
  if $rt images &>/dev/null 2>&1; then
    local img_count
    img_count=$($rt images -q 2>/dev/null | wc -l | tr -d ' ')
    pass "${rt} images" "${img_count} image(s) cached locally"
  else
    fail "${rt} images failed"
  fi

  section "Pull test (hello-world)"
  if $rt image inspect hello-world &>/dev/null 2>&1; then
    pass "hello-world image already present (skipping pull)"
  else
    if $rt pull hello-world &>/dev/null 2>&1; then
      pass "hello-world pull succeeded"
    else
      warn "Could not pull hello-world" "network access or registry issue"
      suggest "Check network connectivity and registry access"
    fi
  fi

  section "Run test (hello-world)"
  if $rt run --rm hello-world &>/dev/null 2>&1; then
    pass "hello-world run succeeded"
  else
    fail "hello-world run failed — something is wrong with the runtime"
    suggest "${rt} run --rm hello-world   # run manually to see error"
  fi
}

# =============================================================================
# SECTION 6 — COMPOSE
# =============================================================================

check_compose() {
  header "Compose"
  local rt="$DETECTED_RUNTIME"

  if [[ "$DAEMON_OK" == false ]]; then
    info "Skipping — daemon not reachable"
    return
  fi

  section "Compose availability"
  local compose
  compose=$(compose_cmd)

  if [[ -z "$compose" ]]; then
    fail "No Compose implementation found"
    if [[ "$rt" == "docker" ]]; then
      suggest "brew install docker-compose   # standalone"
      suggest "Or upgrade Docker Desktop     # includes compose plugin"
    else
      suggest "pip3 install podman-compose"
      suggest "Or: brew install podman-compose"
    fi
    return
  fi

  local compose_version
  compose_version=$($compose version 2>/dev/null | head -1) || compose_version="unknown"
  pass "Compose available" "$compose (${compose_version})"

  # Check for compose plugin vs standalone
  section "Compose type"
  if [[ "$compose" == *"compose"* && "$compose" != *"-"* ]]; then
    pass "Using native compose plugin (recommended)"
  else
    warn "Using standalone compose (legacy)" "consider upgrading to plugin"
  fi
}

# =============================================================================
# SECTION 7 — STORAGE
# =============================================================================

check_storage() {
  header "Storage"
  local rt="$DETECTED_RUNTIME"

  if [[ "$DAEMON_OK" == false ]]; then
    info "Skipping — daemon not reachable"
    return
  fi

  section "Storage driver"
  local driver
  if [[ "$rt" == "docker" ]]; then
    driver=$(_timeout 5 docker info --format '{{.Driver}}' 2>/dev/null) || driver="unknown"
  else
    driver=$(_timeout 5 podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null) || driver="unknown"
  fi

  case "$driver" in
    overlay|overlay2)
      pass "Storage driver" "$driver (recommended)"
      ;;
    vfs)
      warn "Storage driver is vfs" "slow — overlay2 preferred"
      suggest "Reconfigure ${rt} to use overlay2 driver"
      ;;
    "")
      warn "Could not determine storage driver"
      ;;
    *)
      pass "Storage driver" "$driver"
      ;;
  esac

  section "Storage root"
  local storage_root
  if [[ "$rt" == "docker" ]]; then
    storage_root=$(_timeout 5 docker info --format '{{.DockerRootDir}}' 2>/dev/null) || storage_root="unknown"
  else
    storage_root=$(_timeout 5 podman info --format '{{.Store.GraphRoot}}' 2>/dev/null) || storage_root="unknown"
  fi
  pass "Storage root" "$storage_root"

  section "Disk space"
  if [[ "$rt" == "podman" && "$storage_root" == /var/* ]]; then
    # Storage root is inside the Podman machine VM — not accessible from the macOS host.
    # Use `podman system df` instead which queries through the socket.
    if $rt system df &>/dev/null 2>&1; then
      local reclaimable
      reclaimable=$($rt system df 2>/dev/null | awk 'NR>1{print $1": "$4}' | tr '\n' '  ') || reclaimable="?"
      pass "Podman VM disk usage (via system df)" "$reclaimable"
    else
      info "Podman storage is inside the VM — run 'podman system df' for usage"
    fi
  elif [[ "$storage_root" != "unknown" && -d "$storage_root" ]]; then
    local avail_pct
    avail_pct=$(df -P "$storage_root" 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%') || avail_pct=0
    local avail_human
    avail_human=$(df -Ph "$storage_root" 2>/dev/null | awk 'NR==2{print $4}') || avail_human="?"
    if [[ "$avail_pct" -gt 90 ]]; then
      fail "Disk usage at ${avail_pct}% — only ${avail_human} free" "risk of container/image failures"
      suggest "${rt} system prune -af   # remove unused images and containers"
    elif [[ "$avail_pct" -gt 75 ]]; then
      warn "Disk usage at ${avail_pct}% — ${avail_human} free" "consider pruning"
      suggest "${rt} system prune"
    else
      pass "Disk usage ${avail_pct}%" "${avail_human} free"
    fi
  else
    info "Could not determine disk usage for ${storage_root}"
  fi

  section "Volumes"
  local vol_count
  vol_count=$($rt volume ls -q 2>/dev/null | wc -l | tr -d ' ') || vol_count=0
  local dangling_count
  dangling_count=$($rt volume ls -f dangling=true -q 2>/dev/null | wc -l | tr -d ' ') || dangling_count=0
  pass "Total volumes" "$vol_count"
  if [[ "$dangling_count" -gt 0 ]]; then
    warn "Dangling volumes" "${dangling_count} unused volume(s) consuming disk"
    if [[ "$FIX" == true ]]; then
      $rt volume prune -f &>/dev/null 2>&1 && fixed "Pruned ${dangling_count} dangling volume(s)" || \
        warn "Could not prune dangling volumes"
    else
      suggest "${rt} volume prune"
    fi
  else
    pass "Dangling volumes" "none"
  fi

  section "System disk usage"
  if $rt system df &>/dev/null 2>&1; then
    local size_info
    size_info=$($rt system df 2>/dev/null | tail -n +2 | awk '{print $1": "$4}' | tr '\n' '  ') || true
    pass "${rt} system df" "$size_info"
  else
    info "${rt} system df not supported"
  fi
}

# =============================================================================
# SECTION 8 — NETWORKING
# =============================================================================

check_networking() {
  header "Networking"
  local rt="$DETECTED_RUNTIME"

  if [[ "$DAEMON_OK" == false ]]; then
    info "Skipping — daemon not reachable"
    return
  fi

  section "Networks"
  local net_count
  net_count=$($rt network ls -q 2>/dev/null | wc -l | tr -d ' ') || net_count=0
  pass "Networks defined" "$net_count"

  section "Bridge network"
  # Podman's built-in default network is named "podman", not "bridge"
  local default_net="bridge"
  [[ "$rt" == "podman" ]] && default_net="podman"
  # Use inspect rather than parsing ls output — more reliable across versions
  if $rt network inspect "$default_net" &>/dev/null 2>&1; then
    pass "Default network exists" "${default_net}"
  else
    warn "Default ${rt} network '${default_net}' not found"
    if [[ "$FIX" == true ]]; then
      $rt network create "$default_net" &>/dev/null 2>&1 && fixed "Created ${default_net} network" || \
        warn "Could not create ${default_net} network"
    else
      suggest "${rt} network create ${default_net}"
    fi
  fi

  section "Custom networks"
  local custom_nets
  custom_nets=$($rt network ls --format '{{.Name}}' 2>/dev/null | grep -vE "^(bridge|host|none|podman)$") || custom_nets=""
  if [[ -n "$custom_nets" ]]; then
    while IFS= read -r net; do
      [[ -z "$net" ]] && continue
      local driver
      driver=$($rt network inspect "$net" --format '{{.Driver}}' 2>/dev/null) || driver="unknown"
      pass "Custom network: ${net}" "driver: ${driver}"
    done <<< "$custom_nets"
  else
    info "No custom networks found (expected for fresh install)"
  fi

  section "DNS resolution (container)"
  if $rt run --rm --network bridge alpine nslookup google.com &>/dev/null 2>&1; then
    pass "Container DNS resolution works" "nslookup google.com via bridge"
  else
    warn "Container DNS resolution failed or alpine not available"
    suggest "${rt} pull alpine && ${rt} run --rm alpine nslookup google.com"
  fi

  section "Host-to-container connectivity"
  if [[ "$rt" == "docker" ]]; then
    local host_ip
    host_ip=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null) || host_ip="unknown"
    if [[ -n "$host_ip" && "$host_ip" != "unknown" ]]; then
      pass "Bridge gateway (host-facing IP)" "$host_ip"
    else
      warn "Could not determine bridge gateway IP"
    fi
  fi

  if [[ "$rt" == "podman" ]]; then
    local host_ip
    host_ip=$(podman network inspect podman --format '{{range .Subnets}}{{.Gateway}}{{end}}' 2>/dev/null) || host_ip="unknown"
    if [[ -n "$host_ip" && "$host_ip" != "unknown" ]]; then
      pass "Podman network gateway" "$host_ip"
    else
      warn "Could not determine Podman network gateway"
    fi
  fi
}

# =============================================================================
# SECTION 9 — PORT CHECKS
# =============================================================================

check_ports() {
  header "Port Checks"
  local rt="$DETECTED_RUNTIME"

  if [[ "$DAEMON_OK" == false ]]; then
    info "Skipping — daemon not reachable"
    return
  fi

  section "Published container ports"
  local port_mappings
  port_mappings=$($rt ps --format '{{.Ports}}' 2>/dev/null | grep -v "^$") || port_mappings=""

  if [[ -z "$port_mappings" ]]; then
    info "No published ports from running containers"
  else
    while IFS= read -r mapping; do
      [[ -z "$mapping" ]] && continue
      pass "Published port mapping" "$mapping"
    done <<< "$port_mappings"
  fi

  if [[ "$CHECK_PORTS" == true ]]; then
    section "Common port conflict scan"

    # Ports commonly used in HashiCorp / dev stacks
    declare -A WELL_KNOWN_PORTS=(
      [8200]="Vault"
      [8201]="Vault cluster"
      [4646]="Nomad HTTP"
      [4647]="Nomad RPC"
      [4648]="Nomad Serf"
      [8500]="Consul HTTP"
      [8600]="Consul DNS"
      [5432]="PostgreSQL"
      [3306]="MySQL"
      [6379]="Redis"
      [9200]="Elasticsearch"
      [5601]="Kibana"
      [9090]="Prometheus"
      [3000]="Grafana"
      [80]="HTTP"
      [443]="HTTPS"
      [8080]="HTTP alt"
      [8443]="HTTPS alt"
    )

    for port in $(echo "${!WELL_KNOWN_PORTS[@]}" | tr ' ' '\n' | sort -n); do
      local service="${WELL_KNOWN_PORTS[$port]}"
      local pid
      pid=$(lsof -ti tcp:"$port" 2>/dev/null | head -1) || pid=""
      if [[ -n "$pid" ]]; then
        local proc
        proc=$(ps -p "$pid" -o comm= 2>/dev/null) || proc="unknown"
        if $rt ps --format '{{.Ports}}' 2>/dev/null | grep -q ":${port}->"; then
          pass "Port ${port} (${service})" "in use by container (expected)"
        else
          warn "Port ${port} (${service})" "in use by host process: ${proc} (PID ${pid})"
          suggest "kill ${pid}   # or: lsof -i tcp:${port}"
        fi
      else
        if [[ "$VERBOSE" == true ]]; then
          pass "Port ${port} (${service})" "free"
        fi
      fi
    done
  fi
}

# =============================================================================
# SECTION 10 — SERVICE HEALTH CHECKS
# =============================================================================

check_services() {
  if [[ "$CHECK_SERVICES" == false ]]; then return; fi
  header "Service Health Checks"
  local rt="$DETECTED_RUNTIME"

  declare -A SERVICES=(
    ["vault"]="8200"
    ["consul"]="8500"
    ["nomad"]="4646"
    ["postgres"]="5432"
  )

  declare -A SERVICE_HEALTH=(
    ["vault"]="http://localhost:8200/v1/sys/health"
    ["consul"]="http://localhost:8500/v1/status/leader"
    ["nomad"]="http://localhost:4646/v1/status/leader"
    ["postgres"]=""
  )

  for svc in vault consul nomad postgres; do
    local port="${SERVICES[$svc]}"
    local health_url="${SERVICE_HEALTH[$svc]}"

    section "${svc^} (port ${port})"

    # Is there a container running this service?
    local container_id
    container_id=$($rt ps --format '{{.ID}} {{.Image}} {{.Ports}}' 2>/dev/null | \
      grep -i "$svc" | awk '{print $1}' | head -1) || container_id=""

    if [[ -n "$container_id" ]]; then
      pass "Container running" "$container_id"
    else
      # Check if port is listening anyway (may be host-installed)
      local listening
      listening=$(lsof -ti tcp:"$port" 2>/dev/null | head -1) || listening=""
      if [[ -n "$listening" ]]; then
        info "No container found but port ${port} is in use (host-installed?)"
      else
        warn "${svc^} container not found and port ${port} not listening"
        _suggest_service_start "$svc" "$rt"
        continue
      fi
    fi

    # HTTP health check
    if [[ -n "$health_url" ]]; then
      local http_code
      http_code=$(curl -sk -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null) || http_code="000"
      case "$http_code" in
        200|204|301|302)
          pass "${svc^} HTTP health check" "HTTP ${http_code} at ${health_url}"
          ;;
        429|503|429)
          warn "${svc^} health check returned ${http_code}" "may be initializing"
          ;;
        000)
          fail "${svc^} not reachable at ${health_url}"
          _suggest_service_start "$svc" "$rt"
          ;;
        *)
          warn "${svc^} returned unexpected HTTP ${http_code}" "$health_url"
          ;;
      esac
    fi

    # Vault-specific: seal status
    if [[ "$svc" == "vault" ]]; then
      local sealed
      sealed=$(curl -sk http://localhost:8200/v1/sys/seal-status 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print('sealed' if d.get('sealed') else 'unsealed')" 2>/dev/null) || sealed="unknown"
      if [[ "$sealed" == "sealed" ]]; then
        warn "Vault is sealed" "run: vault operator unseal"
      elif [[ "$sealed" == "unsealed" ]]; then
        pass "Vault seal status" "unsealed"
      else
        info "Could not determine Vault seal status"
      fi
    fi

    # PostgreSQL-specific: pg_isready
    if [[ "$svc" == "postgres" && -n "$container_id" ]]; then
      if $rt exec "$container_id" pg_isready &>/dev/null 2>&1; then
        pass "PostgreSQL pg_isready" "accepting connections"
      else
        warn "PostgreSQL container running but pg_isready failed"
      fi
    fi
  done
}

_suggest_service_start() {
  local svc="$1"
  local rt="$2"
  case "$svc" in
    vault)
      suggest "${rt} run -d --name vault -p 8200:8200 -e VAULT_DEV_ROOT_TOKEN_ID=root hashicorp/vault"
      ;;
    consul)
      suggest "${rt} run -d --name consul -p 8500:8500 hashicorp/consul agent -dev -client 0.0.0.0"
      ;;
    nomad)
      suggest "${rt} run -d --name nomad -p 4646:4646 hashicorp/nomad agent -dev"
      ;;
    postgres)
      suggest "${rt} run -d --name postgres -p 5432:5432 -e POSTGRES_PASSWORD=secret postgres:16"
      ;;
  esac
}


# =============================================================================
# SECTION 12 — CONTAINER HEALTH STATUS
# =============================================================================

check_container_health() {
  header "Container Health Status"
  local rt="$DETECTED_RUNTIME"

  if [[ "$DAEMON_OK" == false ]]; then
    info "Skipping — daemon not reachable"
    return
  fi

  local running
  running=$($rt ps -q 2>/dev/null) || running=""

  if [[ -z "$running" ]]; then
    info "No running containers to inspect"
    return
  fi

  section "Per-container health"
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue

    local name image health_status
    name=$($rt inspect "$cid" --format '{{.Name}}' 2>/dev/null | sed 's|^/||') || name="$cid"
    image=$($rt inspect "$cid" --format '{{.Config.Image}}' 2>/dev/null) || image="unknown"
    health_status=$($rt inspect "$cid" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null) || health_status="none"

    case "$health_status" in
      healthy)
        pass "Container: ${name}" "healthy — ${image}"
        ;;
      unhealthy)
        fail "Container: ${name}" "UNHEALTHY — ${image}"
        local last_log
        last_log=$($rt inspect "$cid" --format '{{range .State.Health.Log}}{{.Output}}{{end}}' 2>/dev/null | tail -1 | tr -d '\n') || last_log=""
        [[ -n "$last_log" ]] && info "Last healthcheck output: ${last_log:0:120}"
        suggest "$rt inspect ${cid} --format '{{json .State.Health}}' | python3 -m json.tool"
        ;;
      starting)
        warn "Container: ${name}" "health still initializing — ${image}"
        info "Wait for HEALTHCHECK interval to elapse, then re-run"
        ;;
      none)
        # Some upstream images don't ship a HEALTHCHECK — downgrade to info for known ones
        if echo "$image" | grep -qE "keycloak|osixia|moby/buildkit"; then
          info "Container: ${name} — no HEALTHCHECK (upstream image: ${image})"
        else
          warn "Container: ${name}" "no HEALTHCHECK defined — ${image}"
          info "Consider adding HEALTHCHECK to the image or compose service"
        fi
        ;;
      *)
        warn "Container: ${name}" "unknown health state: ${health_status}"
        ;;
    esac

    # Surface recent FATAL/PANIC log lines only — ERROR is too noisy (app-level issues
    # like lease renewals, API errors are real but not runtime health problems).
    # Use --verbose to also surface ERROR lines.
    local fatal_filter="(FATAL|PANIC)"
    [[ "$VERBOSE" == true ]] && fatal_filter="(ERROR|FATAL|PANIC)"
    local error_lines
    error_lines=$($rt logs --tail 50 "$cid" 2>&1 \
      | grep -iE "$fatal_filter" \
      | grep -vE "certificate counts not found|error reading current month certificate|error reading previous month certificate|lease renewal failed|failed to renew|Error making API request" \
      | tail -3) || error_lines=""
    if [[ -n "$error_lines" ]]; then
      warn "Log errors in ${name}" "recent ${fatal_filter} entries found"
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        info "${line:0:120}"
      done <<< "$error_lines"
    fi

  done <<< "$running"
}

# =============================================================================
# SECTION 13 — IMAGE PROVENANCE
# =============================================================================

check_image_provenance() {
  header "Image Provenance"
  local rt="$DETECTED_RUNTIME"

  if [[ "$DAEMON_OK" == false ]]; then
    info "Skipping — daemon not reachable"
    return
  fi

  # Trusted registry prefixes
  local -a TRUSTED_PREFIXES=(
    "docker.io/library/"
    "library/"
    "hashicorp/"
    "docker.io/hashicorp/"
    "docker.io/moby/"
    "moby/"
    "ghcr.io/"
    "gcr.io/"
    "public.ecr.aws/"
    "quay.io/"
    "registry.k8s.io/"
  )

  local running
  running=$($rt ps -q 2>/dev/null) || running=""

  if [[ -z "$running" ]]; then
    info "No running containers — checking all local images instead"
    running=$($rt images -q 2>/dev/null) || running=""
    if [[ -z "$running" ]]; then
      info "No local images found"
      return
    fi
    _check_images_by_ids "$running"
    return
  fi

  section "Images in use by running containers"
  local seen_images=()
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    local image image_id created_raw
    image=$($rt inspect "$cid" --format '{{.Config.Image}}' 2>/dev/null) || image="unknown"
    image_id=$($rt inspect "$cid" --format '{{.Image}}' 2>/dev/null | cut -c1-12) || image_id="?"
    created_raw=$($rt inspect "$cid" --format '{{.Created}}' 2>/dev/null) || created_raw=""

    # Dedup
    if printf '%s\n' "${seen_images[@]}" | grep -qx "$image"; then
      continue
    fi
    seen_images+=("$image")

    local issues=()

    # Locally built images (no registry prefix, or docker.io/library/<project>)
    # are identified by having no dots in the registry component — skip registry
    # and :latest checks for these since they are intentionally local builds.
    local is_local_build=false
    if echo "$image" | grep -qE "^docker\.io/library/[^/]+:latest$|^[^./][^/]*:[^/]+$"; then
      # docker.io/library/<name>:latest with a project-style name (contains underscore/dash)
      # or a plain name:tag with no registry — treat as local build
      local img_name
      img_name=$(echo "$image" | sed 's|.*/||' | cut -d: -f1)
      if echo "$img_name" | grep -qE "[_-]"; then
        is_local_build=true
      fi
    fi

    # :latest tag check — skip for local builds
    if [[ "$is_local_build" == false ]] && echo "$image" | grep -qE ":latest$|^[^:]+$"; then
      issues+=("uses :latest tag — non-reproducible")
    fi

    # registry check — only flag images from genuinely unknown registries,
    # not Docker Hub community images (docker.io/user/image is Docker Hub, not "unofficial")
    local trusted=false
    for prefix in "${TRUSTED_PREFIXES[@]}"; do
      if echo "$image" | grep -qi "^${prefix}"; then
        trusted=true
        break
      fi
    done
    # bare image name (e.g. "postgres") and docker.io/* are Docker Hub — trusted registry
    if [[ "$image" != *"/"* || "$image" =~ ^[a-z0-9_-]+:[a-z0-9._-]+$ ]]; then
      trusted=true
    fi
    if echo "$image" | grep -q "^docker\.io/"; then
      trusted=true
    fi
    # Flag only truly unknown registries (not docker.io, not known prefixes)
    if [[ "$trusted" == false && "$is_local_build" == false ]]; then
      local registry="${image%%/*}"
      issues+=("unknown registry: ${registry} — verify image source")
    fi

    # image age check
    if [[ -n "$created_raw" ]]; then
      local created_epoch now_epoch age_days
      # Normalise both Docker format (2024-01-15T10:30:45.123Z) and
      # Podman format (2024-01-15 10:30:45.123 +0000 UTC) to YYYY-MM-DDTHH:MM:SS
      local created_normalised
      created_normalised=$(echo "$created_raw" | sed 's/ /T/' | cut -dT -f1-2 | cut -d. -f1)
      if [[ $_DATE_MACOS -eq 1 ]]; then
        created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$created_normalised" "+%s" 2>/dev/null) || created_epoch=0
      else
        created_epoch=$(date -d "$created_normalised" "+%s" 2>/dev/null) || created_epoch=0
      fi
      now_epoch=$(date "+%s")
      age_days=$(( (now_epoch - created_epoch) / 86400 ))
      # Only report if parse succeeded (epoch > 0 means year > 1970)
      if [[ "$created_epoch" -gt 0 ]]; then
        if [[ "$age_days" -gt 90 ]]; then
          issues+=("image is ${age_days} days old — consider refreshing")
        elif [[ "$age_days" -gt 30 ]]; then
          issues+=("image is ${age_days} days old")
        fi
      fi
    fi

    if [[ ${#issues[@]} -eq 0 ]]; then
      pass "Image: ${image}" "id: ${image_id}"
    else
      local issue_str
      issue_str=$(IFS='; '; echo "${issues[*]}")
      warn "Image: ${image}" "${issue_str}"
    fi
  done <<< "$running"

  section "Dangling images"
  local dangling
  dangling=$($rt images -f dangling=true -q 2>/dev/null | wc -l | tr -d ' ') || dangling=0
  if [[ "$dangling" -gt 0 ]]; then
    warn "Dangling images" "${dangling} untagged image(s) consuming disk"
    if [[ "$FIX" == true ]]; then
      $rt image prune -f &>/dev/null 2>&1 && fixed "Pruned ${dangling} dangling image(s)" ||         warn "Could not prune dangling images"
    else
      suggest "${rt} image prune"
    fi
  else
    pass "Dangling images" "none"
  fi
}

_check_images_by_ids() {
  local ids="$1"
  while IFS= read -r iid; do
    [[ -z "$iid" ]] && continue
    local repo tag
    repo=$(docker image inspect "$iid" --format '{{index .RepoTags 0}}' 2>/dev/null) || repo="<untagged>"
    if [[ "$repo" == "<untagged>" || -z "$repo" ]]; then
      warn "Untagged image" "$iid"
    else
      pass "Local image" "$repo"
    fi
  done <<< "$ids"
}

# =============================================================================
# SECTION 14 — PRIVILEGED CONTAINER DETECTION
# =============================================================================

check_privileged_containers() {
  header "Privileged Container Detection"
  local rt="$DETECTED_RUNTIME"

  if [[ "$DAEMON_OK" == false ]]; then
    info "Skipping — daemon not reachable"
    return
  fi

  local running
  running=$($rt ps -q 2>/dev/null) || running=""

  if [[ -z "$running" ]]; then
    info "No running containers to inspect"
    return
  fi

  section "Security posture per container"
  local all_clean=true

  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue

    local name image
    name=$($rt inspect "$cid" --format '{{.Name}}' 2>/dev/null | sed 's|^/||') || name="$cid"
    image=$($rt inspect "$cid" --format '{{.Config.Image}}' 2>/dev/null) || image="unknown"

    # Skip Docker-managed infrastructure containers — user has no control over them
    if echo "$name" | grep -qE "^buildx_buildkit_"; then
      pass "Container: ${name}" "Docker-managed buildx container (skipped)"
      continue
    fi

    local privileged cap_add pid_mode network_mode user
    privileged=$($rt inspect "$cid" --format '{{.HostConfig.Privileged}}' 2>/dev/null) || privileged="false"
    cap_add=$($rt inspect "$cid" --format '{{join .HostConfig.CapAdd ", "}}' 2>/dev/null) || cap_add=""
    pid_mode=$($rt inspect "$cid" --format '{{.HostConfig.PidMode}}' 2>/dev/null) || pid_mode=""
    network_mode=$($rt inspect "$cid" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null) || network_mode=""
    user=$($rt inspect "$cid" --format '{{.Config.User}}' 2>/dev/null) || user=""

    local container_issues=()
    local container_severity="pass"

    # Privileged mode — critical
    if [[ "$privileged" == "true" ]]; then
      container_issues+=("--privileged (full host access)")
      container_severity="fail"
    fi

    # Dangerous capabilities
    if echo "$cap_add" | grep -qiE "(SYS_ADMIN|ALL|NET_ADMIN|SYS_PTRACE)"; then
      container_issues+=("dangerous cap-add: ${cap_add}")
      container_severity="fail"
    elif [[ -n "$cap_add" ]]; then
      # IPC_LOCK is required by Vault to mlock secrets in memory — expected, not dangerous
      if echo "$cap_add" | grep -qiE "^IPC_LOCK$|^CAP_IPC_LOCK$"; then
        : # intentionally silent — known safe capability for Vault
      else
        container_issues+=("cap-add: ${cap_add}")
        [[ "$container_severity" != "fail" ]] && container_severity="warn"
      fi
    fi

    # PID namespace sharing
    if [[ "$pid_mode" == "host" ]]; then
      container_issues+=("--pid=host (host PID namespace)")
      [[ "$container_severity" != "fail" ]] && container_severity="warn"
    fi

    # Host networking
    if [[ "$network_mode" == "host" ]]; then
      container_issues+=("--network=host (host network stack)")
      [[ "$container_severity" != "fail" ]] && container_severity="warn"
    fi

    # Running as root — downgrade to info for known workshop images (upstream third-party)
    if [[ -z "$user" || "$user" == "root" || "$user" == "0" ]]; then
      local is_workshop_container=false
      if echo "$name" | grep -qE "^zero_trust_"; then
        is_workshop_container=true
      fi
      if [[ "$is_workshop_container" == true ]]; then
        # Track separately so it shows as info, not warn
        container_issues+=("running as root — upstream image, no USER set")
        # Don't upgrade severity for workshop containers
      else
        container_issues+=("running as root (no USER set)")
        [[ "$container_severity" == "pass" ]] && container_severity="warn"
      fi
    fi

    local issue_str=""
    [[ ${#container_issues[@]} -gt 0 ]] && issue_str=$(IFS='; '; echo "${container_issues[*]}")

    case "$container_severity" in
      fail)
        all_clean=false
        fail "Container: ${name}" "${issue_str}"
        info "Image: ${image}"
        info "Security risk: privilege escalation / confused deputy attack surface"
        suggest "Remove --privileged and scope capabilities to minimum required"
        suggest "Reference: https://docs.docker.com/engine/reference/run/#runtime-privilege-and-linux-capabilities"
        ;;
      warn)
        all_clean=false
        warn "Container: ${name}" "${issue_str}"
        info "Image: ${image}"
        ;;
      pass)
        if [[ ${#container_issues[@]} -gt 0 ]]; then
          # Has notes (e.g. running as root on workshop container) but not serious enough to warn
          pass "Container: ${name}" "${issue_str}"
        else
          pass "Container: ${name}" "no privilege escalation flags"
        fi
        ;;
    esac

  done <<< "$running"

  if [[ "$all_clean" == true ]]; then
    pass "All running containers" "no privileged or dangerous capability flags detected"
  fi

  section "User namespace remapping"
  if [[ "$rt" == "docker" ]]; then
    local userns
    userns=$(_timeout 5 docker info --format '{{.SecurityOptions}}' 2>/dev/null) || userns=""
    if echo "$userns" | grep -q "userns"; then
      pass "User namespace remapping" "enabled (recommended)"
    else
      warn "User namespace remapping not enabled" "containers run as real root on host"
      suggest "Configure userns-remap in /etc/docker/daemon.json"
    fi
  fi
}

# =============================================================================
# SECTION 11 — SUMMARY SCORECARD
# =============================================================================

_health_grade() {
  # Returns: "grade|label|color|bar_color|emoji"
  # Score = PASS / (PASS + WARN + FAIL) * 100, penalised by failures
  local total=$(( PASS + WARN + FAIL ))
  local score=0
  if [[ $total -gt 0 ]]; then
    score=$(( (PASS * 100) / total ))
  fi

  # Hard-downgrade on failures regardless of score
  if [[ $FAIL -ge 3 ]]; then
    echo "F|Broken|${RED}|${RED}|💀|${score}"
  elif [[ $FAIL -ge 1 ]]; then
    echo "D|Critical|${RED}|${RED}|🔴|${score}"
  elif [[ $WARN -ge 3 ]]; then
    echo "C|Degraded|\033[0;33m|\033[0;33m|🟠|${score}"
  elif [[ $WARN -ge 1 ]]; then
    echo "B|Good|${YELLOW}|${YELLOW}|🟡|${score}"
  else
    echo "A|Healthy|${GREEN}|${GREEN}|🟢|${score}"
  fi
}

_score_bar() {
  local score="$1"
  local bar_color="$2"
  local filled=$(( score / 5 ))    # 20 chars = 100%
  local empty=$(( 20 - filled ))
  local bar=""
  local i=0
  while [[ $i -lt $filled ]]; do
    bar+="█"
    i=$(( i + 1 ))
  done
  i=0
  while [[ $i -lt $empty ]]; do
    bar+="░"
    i=$(( i + 1 ))
  done
  echo -e "${bar_color}${bar}${RESET}"
}

print_summary() {
  local grade_info
  grade_info=$(_health_grade)

  local grade label color bar_color emoji score
  IFS='|' read -r grade label color bar_color emoji score <<< "$grade_info"

  local total=$(( PASS + WARN + FAIL ))
  local bar
  bar=$(_score_bar "$score" "$bar_color")

  echo ""
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${BLUE}  Summary Scorecard${RESET}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════${RESET}"
  echo ""
  echo -e "  Runtime : ${BOLD}${CYAN}${DETECTED_RUNTIME}${RESET}"
  if [[ "$FIX" == true ]]; then
    echo -e "  Mode    : auto-fix enabled"
  else
    echo -e "  Mode    : detect only"
  fi
  echo ""

  # Health grade block
  echo -e "  ${BOLD}Health Grade${RESET}"
  echo -e "  ${emoji}  ${color}${BOLD}${grade} — ${label}${RESET}"
  echo -e "  ${bar}  ${color}${BOLD}${score}%${RESET}"
  echo ""

  # Check counts
  echo -e "  ${GREEN}✔ Pass  : ${PASS}${RESET}"
  echo -e "  ${YELLOW}⚠ Warn  : ${WARN}${RESET}"
  echo -e "  ${RED}✘ Fail  : ${FAIL}${RESET}"
  if [[ "$FIX" == true ]]; then
    echo -e "  ${GREEN}⚙ Fixed : ${FIXED}${RESET}"
  fi
  echo -e "  ${DIM}  Total : ${total} check(s) run${RESET}"
  echo ""

  # Verdict line
  if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}✔ Runtime is healthy and ready.${RESET}"
  elif [[ $FAIL -eq 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}⚠ Runtime functional with ${WARN} warning(s). Review suggestions above.${RESET}"
  elif [[ $FAIL -ge 3 ]]; then
    echo -e "  ${RED}${BOLD}💀 ${FAIL} failures. Runtime is broken — fix before use.${RESET}"
  else
    echo -e "  ${RED}${BOLD}✘ ${FAIL} failure(s) detected. Address issues above before using ${DETECTED_RUNTIME}.${RESET}"
  fi
  echo ""

  if [[ "$FIX" == true && $FIXED -eq 0 && $FAIL -gt 0 ]]; then
    echo -e "  ${DIM}Note: --fix was set but no automatic corrections were possible.${RESET}"
    echo -e "  ${DIM}      Some issues require manual intervention.${RESET}"
    echo ""
  fi
}

print_json_summary() {
  if [[ "$JSON_OUTPUT" == false ]]; then return; fi

  local _ginfo
  _ginfo=$(_health_grade)
  local _grade _label _color _bar _emoji _score
  IFS='|' read -r _grade _label _color _bar _emoji _score <<< "$_ginfo"

  echo ""
  echo "--- JSON OUTPUT ---"
  echo "{"
  echo "  \"runtime\": \"${DETECTED_RUNTIME}\","
  echo "  \"grade\": \"${_grade}\","
  echo "  \"label\": \"${_label}\","
  echo "  \"score\": ${_score},"
  echo "  \"pass\": ${PASS},"
  echo "  \"warn\": ${WARN},"
  echo "  \"fail\": ${FAIL},"
  echo "  \"fixed\": ${FIXED},"
  echo "  \"checks\": ["
  local total=${#JSON_RESULTS[@]}
  local idx=0
  for entry in "${JSON_RESULTS[@]}"; do
    idx=$((idx + 1))
    if [[ $idx -lt $total ]]; then
      echo "    ${entry},"
    else
      echo "    ${entry}"
    fi
  done
  echo "  ]"
  echo "}"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  clear 2>/dev/null || true
  echo ""
  echo -e "${BOLD}${BLUE}  verify_container_runtime.sh v${VERSION}${RESET}"
  echo -e "${DIM}  Container runtime health check + correction for macOS${RESET}"
  echo ""

  detect_runtime
  check_binary
  check_daemon
  check_machine_state
  check_basic_ops
  check_compose
  check_storage
  check_networking
  check_ports
  check_services
  check_container_health
  check_image_provenance
  check_privileged_containers
  print_summary
  print_json_summary
}

main "$@"
