#!/usr/bin/env bash

set -euo pipefail

BOLD="\033[1m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"
DEBUG_INSPECT="${DEBUG_INSPECT_CONTAINERS:-0}"

declare -A CONTAINER_NAMES=()
while IFS='|' read -r id resolved_name; do
  CONTAINER_NAMES["$id"]="$resolved_name"
done < <(docker ps --format "{{.ID}}|{{.Names}}" | tr -d '\r')

bar() {
  local pct="${1%.*}"
  local filled=$(( pct / 5 ))
  (( filled > 20 )) && filled=20
  local empty=$(( 20 - filled ))
  local color="${GREEN}"
  (( pct >= 75 )) && color="${RED}"
  (( pct >= 40 && pct < 75 )) && color="${YELLOW}"
  local b=""
  local i
  for (( i=0; i<filled; i++ )); do b+="█"; done
  for (( i=0; i<empty;  i++ )); do b+="░"; done
  printf "${color}%s${RESET}" "$b"
}

echo ""
echo -e "${BOLD}${CYAN}=== Container Resource Usage ===${RESET}"
echo -e "${BOLD}$(printf '%-22s %-26s %-8s %-26s %-8s %-18s %-18s' NAME "CPU%" "" "MEMORY" "MEM%" "NET-I/O" "BLOCK-I/O")${RESET}"
echo "$(printf '%.0s─' {1..110})"

docker stats --no-stream --format \
  "{{.ID}}|{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}" \
| tr -d '\r' \
| while IFS='|' read -r id name cpu mem mempct netio blockio; do
    if [[ -n "${CONTAINER_NAMES[$id]:-}" ]]; then
      name="${CONTAINER_NAMES[$id]}"
    fi
    if [[ "$DEBUG_INSPECT" == "1" ]]; then
      printf 'DEBUG id=%q raw=%q\n' "$id" "$name" >&2
    fi
    name="${name#zero_trust_}"
    if [[ "$DEBUG_INSPECT" == "1" ]]; then
      printf 'DEBUG trimmed=%q\n' "$name" >&2
    fi
    cpu_val="${cpu//%/}"
    mem_val="${mempct//%/}"
    cpu_bar=$(bar "$cpu_val")
    mem_bar=$(bar "$mem_val")
    printf "%-22s %s %-8s %s %-8s %-18s %-18s\n" \
      "$name" "$cpu_bar" "$cpu" "$mem_bar" "$mempct" "$netio" "$blockio"
  done

echo ""
echo -e "${BOLD}${CYAN}=== Disk Usage ===${RESET}"
echo "$(printf '%.0s─' {1..70})"

docker system df --format "{{.Type}}|{{.TotalCount}}|{{.Active}}|{{.Size}}|{{.Reclaimable}}" \
| tr -d '\r' \
| awk -F'|' 'BEGIN {
    printf "\033[1m%-20s %-8s %-8s %-14s %s\033[0m\n", "TYPE", "TOTAL", "ACTIVE", "SIZE", "RECLAIMABLE"
  }
  {
    printf "%-20s %-8s %-8s %-14s %s\n", $1, $2, $3, $4, $5
  }'

echo ""
