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
echo -e "${BOLD}${CYAN}=== Container Resource Usage ===${RESET}"

# Header — bar is always W_CPU_BAR visual chars, so header uses plain spaces for that column
total_width=$(( W_NAME + ${#SEP} + W_CPU_BAR + 1 + W_CPU_VAL + ${#SEP} + W_MEM + ${#SEP} + W_NET + ${#SEP} + W_BLOCK ))
printf "${BOLD}%-${W_NAME}s${SEP}%-$(( W_CPU_BAR + 1 + W_CPU_VAL ))s${SEP}%${W_MEM}s${SEP}%-${W_NET}s${SEP}%-${W_BLOCK}s${RESET}\n" \
  "NAME" "CPU" "MEM%" "NET-I/O" "BLOCK-I/O"
printf '%.0s─' $(seq 1 $total_width); echo

docker stats --no-stream --format \
  "{{.ID}}|{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}" \
| tr -d '\r' \
| while IFS='|' read -r id name cpu mem mempct netio blockio; do
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
echo -e "${BOLD}${CYAN}=== Disk Usage ===${RESET}"

docker system df --format "{{.Type}}|{{.TotalCount}}|{{.Active}}|{{.Size}}|{{.Reclaimable}}" \
| tr -d '\r' \
| awk -F'|' -v SEP=" │ " 'BEGIN {
    printf "\033[1m%-16s%s%-7s%s%-7s%s%-12s%s%s\033[0m\n", \
      "TYPE", SEP, "TOTAL", SEP, "ACTIVE", SEP, "SIZE", SEP, "RECLAIMABLE"
    n=16+3+7+3+7+3+12+3+12
    for(i=0;i<n;i++) printf "─"; printf "\n"
  }
  {
    printf "%-16s%s%-7s%s%-7s%s%-12s%s%s\n", $1, SEP, $2, SEP, $3, SEP, $4, SEP, $5
  }'

echo ""
