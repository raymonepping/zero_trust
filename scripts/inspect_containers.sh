#!/usr/bin/env bash

set -euo pipefail

BOLD="\033[1m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
ORANGE="\033[38;5;208m"
RED="\033[31m"
RESET="\033[0m"
DEBUG_INSPECT="${DEBUG_INSPECT_CONTAINERS:-0}"
RUNTIME="auto"
EFFECTIVE_RUNTIME=""

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

  echo "ERROR: unable to detect a supported container runtime" >&2
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
      echo "ERROR: unsupported runtime '${RUNTIME}'. Use docker, podman, or auto." >&2
      exit 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)
      RUNTIME="${2:-}"
      [[ -z "${RUNTIME}" ]] && { echo "ERROR: missing runtime value" >&2; exit 1; }
      shift 2
      ;;
    --help)
      echo "Usage: $(basename "$0") [--runtime docker|podman|auto]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

resolve_runtime

if ! command -v "${EFFECTIVE_RUNTIME}" >/dev/null 2>&1; then
  echo "ERROR: ${EFFECTIVE_RUNTIME} CLI is not installed or not on PATH" >&2
  exit 1
fi

declare -A CONTAINER_NAMES=()
while IFS='|' read -r id resolved_name; do
  CONTAINER_NAMES["$id"]="$resolved_name"
done < <("${EFFECTIVE_RUNTIME}" ps --format "{{.ID}}|{{.Names}}" | tr -d '\r')

bar() {
  local pct="${1%.*}"
  local filled=$(( pct / 5 ))
  (( filled > 20 )) && filled=20
  local empty=$(( 20 - filled ))
  local color="${GREEN}"
  (( pct >= 25 && pct < 50 )) && color="${YELLOW}"
  (( pct >= 50 && pct < 75 )) && color="${ORANGE}"
  (( pct >= 75 )) && color="${RED}"
  local b=""
  local i
  for (( i=0; i<filled; i++ )); do b+="█"; done
  for (( i=0; i<empty;  i++ )); do b+="░"; done
  printf "${color}%s${RESET}" "$b"
}

SEP=" │ "

# Column widths
W_NAME=12
W_CPU_BAR=20   # ████░░░░░░░░░░░░░░░░ = 20 chars
W_CPU_VAL=22   # "2.11 cores (210.82%)" — worst case 3-digit CPU%
W_MEM=8        # right-aligned percentage
W_NET=20
W_BLOCK=20

echo ""
echo -e "${BOLD}${CYAN}=== Container Resource Usage (${EFFECTIVE_RUNTIME}) ===${RESET}"

# Header — bar is always W_CPU_BAR visual chars, so header uses plain spaces for that column
total_width=$(( W_NAME + ${#SEP} + W_CPU_BAR + 1 + W_CPU_VAL + ${#SEP} + W_MEM + ${#SEP} + W_NET + ${#SEP} + W_BLOCK ))
printf "${BOLD}%-${W_NAME}s${SEP}%-$(( W_CPU_BAR + 1 + W_CPU_VAL ))s${SEP}%${W_MEM}s${SEP}%-${W_NET}s${SEP}%-${W_BLOCK}s${RESET}\n" \
  "NAME" "CPU" "MEM%" "NET-I/O" "BLOCK-I/O"
printf '%.0s─' $(seq 1 $total_width); echo

"${EFFECTIVE_RUNTIME}" stats --no-stream --format \
  "{{.ID}}|{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}" \
| tr -d '\r' \
| while IFS='|' read -r id name cpu _mem mempct netio blockio; do
    display_name="$name"
    if [[ -n "${CONTAINER_NAMES[$id]:-}" ]]; then
      display_name="${CONTAINER_NAMES[$id]}"
    fi
    display_name=$(printf '%s' "$display_name" | awk '{sub(/.*zero_trust_/, ""); print}')
    printf '%s|%s|%s|%s|%s\n' \
      "$display_name" "$cpu" "$mempct" "$netio" "$blockio"
  done \
| sort -t '|' -k1,1 \
| while IFS='|' read -r name cpu mempct netio blockio; do
    if [[ "$DEBUG_INSPECT" == "1" ]]; then
      printf 'DEBUG trimmed=%q\n' "$name" >&2
    fi

    cpu_val="${cpu//%/}"
    cpu_cores=$(awk -v cpu="$cpu_val" 'BEGIN { printf "%.2f", cpu / 100 }')
    cpu_display="${cpu_cores} cores (${cpu})"
    cpu_bar=$(bar "$cpu_val")

    # Print bar separately so ANSI codes don't skew subsequent column widths
    printf "%-${W_NAME}s${SEP}" "$name"
    printf "%s" "$cpu_bar"
    printf " %-${W_CPU_VAL}s${SEP}%${W_MEM}s${SEP}%-${W_NET}s${SEP}%-${W_BLOCK}s\n" \
      "$cpu_display" "$mempct" "$netio" "$blockio"
  done

echo ""
echo -e "${BOLD}${CYAN}=== Disk Usage (zero_trust project / ${EFFECTIVE_RUNTIME}) ===${RESET}"

COMPOSE_PROJECT="zero_trust"

# ── Images used by this project ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}Images${RESET}"
printf '%.0s─' $(seq 1 72); echo

project_images=$("${EFFECTIVE_RUNTIME}" ps -a \
  --filter "name=${COMPOSE_PROJECT}_" \
  --format "{{.Image}}" 2>/dev/null | sort -u)

if [[ -z "$project_images" ]]; then
  # Stack not running — read images from compose config
  project_images=$(cd "$(dirname "$0")/.." && "${EFFECTIVE_RUNTIME}" compose config 2>/dev/null \
    | grep -E "^\s+image:" | awk '{print $2}' | sort -u)
fi

total_image_bytes=0
printf "${BOLD}%-50s %10s %s${RESET}\n" "IMAGE" "SIZE" "STATUS"
printf '%.0s─' $(seq 1 72); echo

while IFS= read -r img; do
  [[ -z "$img" ]] && continue
  info=$("${EFFECTIVE_RUNTIME}" image inspect "$img" \
    --format '{{.Size}}|{{.RepoTags}}' 2>/dev/null || echo "")
  if [[ -z "$info" ]]; then
    printf "%-50s %10s %s\n" "$img" "n/a" "(not pulled)"
    continue
  fi
  raw_bytes=$(echo "$info" | cut -d'|' -f1)
  total_image_bytes=$(( total_image_bytes + raw_bytes ))
  size_human=$("${EFFECTIVE_RUNTIME}" image inspect "$img" \
    --format '{{.Size}}' 2>/dev/null \
    | awk '{
        if ($1 >= 1073741824) printf "%.1fGB", $1/1073741824
        else if ($1 >= 1048576) printf "%.1fMB", $1/1048576
        else printf "%.0fKB", $1/1024
      }')
  printf "%-50s %10s\n" "$img" "$size_human"
done <<< "$project_images"

total_img_human=$(echo "$total_image_bytes" | awk '{
  if ($1 >= 1073741824) printf "%.1fGB", $1/1073741824
  else if ($1 >= 1048576) printf "%.1fMB", $1/1048576
  else printf "%.0fKB", $1/1024
}')
printf '%.0s─' $(seq 1 72); echo
printf "${BOLD}%-50s %10s${RESET}\n" "TOTAL" "$total_img_human"

# ── Containers for this project ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}Containers${RESET}"
printf '%.0s─' $(seq 1 72); echo
printf "${BOLD}%-35s %-12s %10s %s${RESET}\n" "NAME" "STATUS" "SIZE" "IMAGE"
printf '%.0s─' $(seq 1 72); echo

ps_args=(-a)
if [[ "${EFFECTIVE_RUNTIME}" == "podman" ]]; then
  ps_args+=(--size)
fi

container_rows=$("${EFFECTIVE_RUNTIME}" ps "${ps_args[@]}" --format "{{.Names}}|{{.Status}}|{{.Size}}|{{.Image}}" 2>/dev/null \
  | grep "^${COMPOSE_PROJECT}_" \
  | sort || true)

if [[ -z "${container_rows}" ]]; then
  printf "%-35s %-12s %10s %s\n" "(none)" "—" "—" "(no matching containers)"
else
  while IFS='|' read -r name status size image; do
    short="${name#"${COMPOSE_PROJECT}"_}"
    # extract the writable-layer size (before the virtual marker)
    layer=$(echo "$size" | grep -oE '^[0-9.]+(B|kB|MB|GB)')
    printf "%-35s %-12s %10s %s\n" \
      "$short" \
      "${status%% (*}" \
      "${layer:-$size}" \
      "$image"
  done <<< "${container_rows}"
fi

# ── Volumes for this project ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Volumes${RESET}"
printf '%.0s─' $(seq 1 72); echo
printf "${BOLD}%-40s %10s %s${RESET}\n" "VOLUME" "SIZE" "STATUS"
printf '%.0s─' $(seq 1 72); echo

total_vol_bytes=0
for vol_suffix in db_data keycloak_data ollama_data \
                  openldap-config openldap-data \
                  vault-agent-secrets vault_data; do
  vol_name="${COMPOSE_PROJECT}_${vol_suffix}"
  exists=$("${EFFECTIVE_RUNTIME}" volume ls --format "{{.Name}}" 2>/dev/null \
    | grep -x "$vol_name" || true)
  if [[ -z "$exists" ]]; then
    printf "%-40s %10s %s\n" "$vol_suffix" "—" "(not created)"
    continue
  fi
  # Run du inside a throwaway container — runtime-managed volume mountpoints on macOS
  # live inside the VM and are not accessible from the host.
  size_raw=$("${EFFECTIVE_RUNTIME}" run --rm \
    -v "${vol_name}:/data:ro" \
    --entrypoint sh \
    alpine -c 'du -sb /data 2>/dev/null | cut -f1' 2>/dev/null || echo "0")
  size_raw="${size_raw//[^0-9]/}"
  size_raw="${size_raw:-0}"
  size_human=$(echo "$size_raw" | awk '{
    if ($1 >= 1073741824) printf "%.1fGB", $1/1073741824
    else if ($1 >= 1048576) printf "%.1fMB", $1/1048576
    else printf "%.0fKB", $1/1024
  }')
  total_vol_bytes=$(( total_vol_bytes + size_raw ))
  printf "%-40s %10s\n" "$vol_suffix" "$size_human"
done

total_vol_human=$(echo "$total_vol_bytes" | awk '{
  if ($1 >= 1073741824) printf "%.1fGB", $1/1073741824
  else if ($1 >= 1048576) printf "%.1fMB", $1/1048576
  else printf "%.0fKB", $1/1024
}')
printf '%.0s─' $(seq 1 72); echo
printf "${BOLD}%-40s %10s${RESET}\n" "TOTAL" "$total_vol_human"

echo ""
