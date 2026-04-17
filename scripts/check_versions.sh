#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# check_versions.sh — Compare workshop image tags against latest available
# Queries Docker Hub (or Quay.io) for the latest semver-stable tag of images
# referenced directly in the Zero Trust workshop docker-compose.yml, plus
# images derived from local Dockerfiles.
#
# Requirements: curl (≥ 7.71 for --retry-all-errors), jq
# Usage:        ./check_versions.sh [--type TYPE] [--json] [--only-upgrades]
#               [--no-cache] [--cache-ttl SEC] [--cache-clear]
# Cache:        Results are cached in ${XDG_CACHE_HOME:-~/.cache}/zero_trust/check_versions.json
#               Default TTL is 3600 s (1 hour). Use --no-cache to force a fresh fetch.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Color / formatting ──────────────────────────────────────────────────────
BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

# ── Pre-flight ──────────────────────────────────────────────────────────────
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}✗ Required tool '${cmd}' not found. Please install it first.${RESET}"
    exit 1
  fi
done

# ── Image registry / CLI filtering ──────────────────────────────────────────
# Format: "label|type|image:current_tag|filter_regex|registry"
#   label         — human-readable service/component name
#   type          — logical group selector for --type
#   filter_regex  — grep -E pattern to select candidate tags
#   registry      — "dockerhub" (default) or "quay"
#
# The filter ensures we pick the right variant (e.g. -ent for enterprise,
# plain semver for OSS, release tags, etc.)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSHOP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

get_from_image() {
  local dockerfile="$1"
  grep -E '^FROM[[:space:]]+' "$dockerfile" | head -1 | awk '{print $2}'
}

DB_BASE_IMAGE="$(get_from_image "${WORKSHOP_DIR}/db/Dockerfile")"
OLLAMA_BASE_IMAGE="$(get_from_image "${WORKSHOP_DIR}/ollama/Dockerfile")"
UBUNTU_SSH_BASE_IMAGE="$(get_from_image "${WORKSHOP_DIR}/ubuntu/Dockerfile")"
DB_BASE_TAG="${DB_BASE_IMAGE##*:}"
DB_MAJOR="${DB_BASE_TAG%%.*}"
UBUNTU_SSH_TAG="${UBUNTU_SSH_BASE_IMAGE##*:}"
UBUNTU_MAJOR="${UBUNTU_SSH_TAG%%.*}"

SELECTED_TYPE=""
OUTPUT_FORMAT="table"
ONLY_UPGRADES=false
NO_COLOR=false
SORT_BY="image"
REQUEST_TIMEOUT=15
REQUEST_RETRIES=2

# Cache
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zero_trust"
CACHE_FILE="${CACHE_DIR}/check_versions.json"
CACHE_TTL=3600
NO_CACHE=false
CACHE_CLEAR=false

set_colors() {
  if [[ "$NO_COLOR" == true ]]; then
    BOLD=""
    DIM=""
    GREEN=""
    YELLOW=""
    RED=""
    CYAN=""
    RESET=""
  fi
}

usage() {
  cat <<EOF
Zero Trust Workshop — Container Version Check

Compares the currently pinned container images used by the workshop against the
latest matching tags published in Docker Hub or Quay.

This includes:
- images defined directly in docker-compose.yml
- base images derived from local Dockerfiles (for example db and ollama)

Usage:
  ./check_versions.sh
  ./check_versions.sh --type TYPE
  ./check_versions.sh --json
  ./check_versions.sh --only-upgrades
  ./check_versions.sh --sort image
  ./check_versions.sh --sort status
  ./check_versions.sh --timeout 15 --retries 2
  ./check_versions.sh --no-color
  ./check_versions.sh --help

Options:
  --type TYPE       Filter the report to a logical image group
                    Supported: all, workshop, storage, hashicorp, database,
                    identity, llm, web, linux
  --json            Emit JSON instead of the text table
  --only-upgrades   Show only rows where current != latest
  --no-color        Disable ANSI colors in table output
  --sort FIELD      Sort by 'image' or 'status' (default: image)
  --timeout SEC     Per-request timeout for registry API calls (default: ${REQUEST_TIMEOUT})
  --retries N       Retry count for registry API calls (default: ${REQUEST_RETRIES})
  --no-cache        Skip the local cache and fetch fresh data from the registry
  --cache-ttl SEC   Cache TTL in seconds (default: ${CACHE_TTL})
  --cache-clear     Delete the local cache file and exit
  -h, --help        Show this help text

Available types:
  all           All tracked images
  workshop      Application services used in the workshop UI/API layer
                - backend
                - frontend

  storage       Storage-related services
                - minio

  hashicorp     HashiCorp platform services
                - vault
                - vault-agent
                - boundary-controller
                - boundary-ingress-worker
                - boundary-egress-worker

  database      PostgreSQL-based services
                - database
                - boundary-db

  identity      Identity and directory services
                - openldap
                - ldap-admin
                - keycloak

  llm           Local LLM runtime
                - ollama

  web           Web ingress / HTTP target components
                - boundary-target (nginx)

  linux         Linux base-image tracking
                - ubuntu-sshd (compared against official ubuntu tags)

Examples:
  ./check_versions.sh
  ./check_versions.sh --type all
  ./check_versions.sh --type workshop
  ./check_versions.sh --type hashicorp --only-upgrades
  ./check_versions.sh --type database --sort status
  ./check_versions.sh --type identity --json
  ./check_versions.sh --type llm --no-color
  ./check_versions.sh --type web
  ./check_versions.sh --type linux
  ./check_versions.sh --type storage --timeout 20 --retries 3

Notes:
- Output is sorted by IMAGE by default.
- Official Docker Hub images such as postgres, nginx, and ubuntu are resolved
  through the library/<image> namespace.
- Floating tags such as latest or alpine are compared against the latest
  matching concrete release where possible.
- JSON output includes digest metadata when the registry API provides it.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)
      [[ $# -lt 2 ]] && { echo -e "${RED}✗ Missing value for --type${RESET}"; usage; exit 1; }
      SELECTED_TYPE="$2"
      shift 2
      ;;
    --json)
      OUTPUT_FORMAT="json"
      shift
      ;;
    --only-upgrades)
      ONLY_UPGRADES=true
      shift
      ;;
    --no-color)
      NO_COLOR=true
      shift
      ;;
    --sort)
      [[ $# -lt 2 ]] && { echo -e "${RED}✗ Missing value for --sort${RESET}"; usage; exit 1; }
      SORT_BY="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -lt 2 ]] && { echo -e "${RED}✗ Missing value for --timeout${RESET}"; usage; exit 1; }
      REQUEST_TIMEOUT="$2"
      shift 2
      ;;
    --retries)
      [[ $# -lt 2 ]] && { echo -e "${RED}✗ Missing value for --retries${RESET}"; usage; exit 1; }
      REQUEST_RETRIES="$2"
      shift 2
      ;;
    --no-cache)
      NO_CACHE=true
      shift
      ;;
    --cache-ttl)
      [[ $# -lt 2 ]] && { echo -e "${RED}✗ Missing value for --cache-ttl${RESET}"; usage; exit 1; }
      CACHE_TTL="$2"
      shift 2
      ;;
    --cache-clear)
      CACHE_CLEAR=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}✗ Unknown argument: $1${RESET}"
      usage
      exit 1
      ;;
  esac
done

set_colors

if [[ -n "$SELECTED_TYPE" && "$SELECTED_TYPE" == "all" ]]; then
  SELECTED_TYPE=""
fi

case "$SORT_BY" in
  image|status) ;;
  *)
    echo -e "${RED}✗ Invalid --sort value: ${SORT_BY}${RESET}"
    usage
    exit 1
    ;;
esac

IMAGES=(
  # vault and vault-agent share the same base image; both rows will always show identical status
  "vault|hashicorp|hashicorp/vault-enterprise:2.0.0-ent|^[0-9]+\.[0-9]+\.[0-9]+-ent$|dockerhub"
  "vault-agent|hashicorp|hashicorp/vault-enterprise:2.0.0-ent|^[0-9]+\.[0-9]+\.[0-9]+-ent$|dockerhub"
  "backend|workshop|repping/zero-trust-backend:1.8.18|^[0-9]+\.[0-9]+\.[0-9]+$|dockerhub"
  "frontend|workshop|repping/zero-trust-frontend:1.8.18|^[0-9]+\.[0-9]+\.[0-9]+$|dockerhub"
  "database|database|${DB_BASE_IMAGE}|^${DB_MAJOR}(\.[0-9]+)?(\.[0-9]+)?$|dockerhub"
  "ollama|llm|${OLLAMA_BASE_IMAGE}|^[0-9]+\.[0-9]+\.[0-9]+$|dockerhub"
  "openldap|identity|osixia/openldap:1.5.0|^[0-9]+\.[0-9]+\.[0-9]+$|dockerhub"
  "ldap-admin|identity|osixia/phpldapadmin:0.9.0|^[0-9]+\.[0-9]+\.[0-9]+$|dockerhub"
  "keycloak|identity|quay.io/keycloak/keycloak:26.6.1|^[0-9]+(\.[0-9]+)?(\.[0-9]+)?$|quay"
  "boundary-db|database|postgres:16.13|^16(\.[0-9]+)?(\.[0-9]+)?$|dockerhub"
  # boundary controller, ingress, and egress all share the same image; all three rows will always show identical status
  "boundary-controller|hashicorp|hashicorp/boundary-enterprise:0.21.2-ent|^[0-9]+\.[0-9]+\.[0-9]+-ent$|dockerhub"
  "boundary-ingress-worker|hashicorp|hashicorp/boundary-enterprise:0.21.2-ent|^[0-9]+\.[0-9]+\.[0-9]+-ent$|dockerhub"
  "boundary-egress-worker|hashicorp|hashicorp/boundary-enterprise:0.21.2-ent|^[0-9]+\.[0-9]+\.[0-9]+-ent$|dockerhub"
  # boundary-target pinned to specific nginx alpine version
  "boundary-target|web|nginx:1.30.0-alpine|^[0-9]+\.[0-9]+\.[0-9]+-alpine$|dockerhub"
  # boundary-ssh built from ubuntu Dockerfile
  "boundary-ssh|linux|${UBUNTU_SSH_BASE_IMAGE}|^${UBUNTU_MAJOR}\.04(\.[0-9]+)?$|dockerhub"
  # minio pinned to specific RELEASE tag (display shortened for readability)
  "minio (2025-09-07)|storage|minio/minio:RELEASE.2025-09-07T16-13-09Z-cpuv1|^RELEASE\.|dockerhub"
)

# ── Helper: registry API access / digest awareness ──────────────────────────
fetch_json() {
  local url="$1"
  curl -fsSL --connect-timeout "$REQUEST_TIMEOUT" --max-time "$REQUEST_TIMEOUT" --retry "$REQUEST_RETRIES" --retry-delay 1 --retry-all-errors "$url" 2>/dev/null
}

get_latest_dockerhub() {
  local repo="$1"
  local filter="$2"
  local page_size=100
  local api_repo="$repo"

  if [[ "$api_repo" != */* ]]; then
    api_repo="library/${api_repo}"
  fi

  # If the filter is anchored to a specific major version (e.g. ^17\. ^16\. ^18\.)
  # append &name=<major>. so that EOL or infrequently-updated tags are not buried
  # past the first page when sorted by last_updated.
  local name_param=""
  if [[ "$filter" =~ ^\^([0-9]+) ]]; then
    name_param="&name=${BASH_REMATCH[1]}."
  fi

  local url="https://hub.docker.com/v2/repositories/${api_repo}/tags?page_size=${page_size}&ordering=last_updated${name_param}"
  local json
  json="$(fetch_json "$url" || true)"
  [[ -z "$json" ]] && return 0

  jq -r --arg filter "$filter" '
    [.results[]
      | select(.name | test($filter))
      | {
          name: .name,
          digest: (
            if (.images | type) == "array" and (.images | length) > 0 then
              (.images[0].digest // "")
            else
              ""
            end
          )
        }
    ]
    | sort_by(.name)
    | .[]
    | @base64
  ' <<< "$json"
}

get_latest_quay() {
  local repo="$1"
  local filter="$2"
  local url="https://quay.io/api/v1/repository/${repo}/tag/?limit=100&onlyActiveTags=true"
  local json
  json="$(fetch_json "$url" || true)"
  [[ -z "$json" ]] && return 0

  jq -r --arg filter "$filter" '
    [.tags[]
      | select(.name | test($filter))
      | {
          name: .name,
          digest: (.manifest_digest // "")
        }
    ]
    | sort_by(.name)
    | .[]
    | @base64
  ' <<< "$json"
}

select_latest_entry() {
  local encoded_entries="$1"
  [[ -z "$encoded_entries" ]] && return 0
  printf '%s\n' "$encoded_entries" \
    | while IFS= read -r item; do
        printf '%s|%s\n' \
          "$(printf '%s' "$item" | base64 -d 2>/dev/null | jq -r '.name')" \
          "$item"
      done \
    | sort -t'|' -k1,1V \
    | tail -1 \
    | cut -d'|' -f2-
}

json_escape() {
  jq -Rn --arg v "$1" '$v'
}

# ── Cache helpers ────────────────────────────────────────────────────────────
# cache_get KEY  — returns a base64-encoded {name,digest} entry if a fresh
#                  cached result exists for KEY, otherwise returns empty.
cache_get() {
  local key="$1"
  [[ ! -f "$CACHE_FILE" ]] && return 0
  local now
  now="$(date +%s)"
  jq -r --arg key "$key" --argjson ttl "$CACHE_TTL" --argjson now "$now" \
    'if has($key) and ($now - .[$key].cached_at) < $ttl then
       {name: .[$key].name, digest: .[$key].digest} | @base64
     else
       ""
     end' \
    "$CACHE_FILE" 2>/dev/null || true
}

# cache_set KEY NAME DIGEST  — writes or refreshes a cache entry atomically.
cache_set() {
  local key="$1" name="$2" digest="$3"
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
  local now tmp
  now="$(date +%s)"
  tmp="$(mktemp "${CACHE_DIR}/check_versions_XXXXXX.tmp" 2>/dev/null)" || return 0
  if [[ -f "$CACHE_FILE" ]]; then
    jq --arg key "$key" --arg name "$name" --arg digest "$digest" --argjson now "$now" \
      '.[$key] = {name: $name, digest: $digest, cached_at: $now}' \
      "$CACHE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$CACHE_FILE" 2>/dev/null || rm -f "$tmp"
  else
    jq -n --arg key "$key" --arg name "$name" --arg digest "$digest" --argjson now "$now" \
      '{($key): {name: $name, digest: $digest, cached_at: $now}}' \
      > "$tmp" 2>/dev/null && mv "$tmp" "$CACHE_FILE" 2>/dev/null || rm -f "$tmp"
  fi
}

# ── Cache-clear early exit ──────────────────────────────────────────────────
if [[ "$CACHE_CLEAR" == true ]]; then
  if [[ -f "$CACHE_FILE" ]]; then
    rm -f "$CACHE_FILE"
    echo -e "${GREEN}✓ Cache cleared: ${CACHE_FILE}${RESET}"
  else
    echo -e "${DIM}Cache file not found (nothing to clear): ${CACHE_FILE}${RESET}"
  fi
  exit 0
fi

# Cache hit/miss counters (populated during the main loop)
CACHE_HITS=0
CACHE_MISSES=0

# ── Main loop / rendering ───────────────────────────────────────────────────
sorted_entries=()
while IFS= read -r entry; do
  sorted_entries+=("$entry")
done < <(printf '%s\n' "${IMAGES[@]}" | sort -t'|' -k1,1f)

filtered_entries=()
for entry in "${sorted_entries[@]}"; do
  IFS='|' read -r label type image_with_tag filter registry <<< "$entry"

  if [[ -n "$SELECTED_TYPE" && "$type" != "$SELECTED_TYPE" ]]; then
    continue
  fi

  filtered_entries+=("$entry")
done

if [[ -n "$SELECTED_TYPE" && ${#filtered_entries[@]} -eq 0 ]]; then
  echo -e "${RED}✗ No images found for type '${SELECTED_TYPE}'${RESET}"
  usage
  exit 1
fi

results=()
upgrades_available=0

for entry in "${filtered_entries[@]}"; do
  IFS='|' read -r label type image_with_tag filter registry <<< "$entry"

  image="${image_with_tag%:*}"
  current_tag="${image_with_tag##*:}"
  api_repo="${image#quay.io/}"
  display="${label} (${image})"

  # Check cache first; fall back to registry fetch on miss or --no-cache
  cache_key="${registry}|${api_repo}|${filter}"
  latest_entry=""
  if [[ "$NO_CACHE" == false ]]; then
    latest_entry="$(cache_get "$cache_key")"
  fi

  if [[ -n "$latest_entry" ]]; then
    CACHE_HITS=$((CACHE_HITS + 1))
  else
    if [[ "$registry" == "quay" ]]; then
      candidates="$(get_latest_quay "$api_repo" "$filter")"
    else
      candidates="$(get_latest_dockerhub "$api_repo" "$filter")"
    fi
    latest_entry="$(select_latest_entry "$candidates" || true)"
    CACHE_MISSES=$((CACHE_MISSES + 1))
    # Persist result to cache for future runs
    if [[ "$NO_CACHE" == false && -n "$latest_entry" ]]; then
      decoded_for_cache="$(printf '%s' "$latest_entry" | base64 -d 2>/dev/null)"
      cache_set "$cache_key" \
        "$(jq -r '.name' <<< "$decoded_for_cache")" \
        "$(jq -r '.digest // ""' <<< "$decoded_for_cache")"
    fi
  fi

  if [[ -z "$latest_entry" ]]; then
    latest="(unknown)"
    latest_digest=""
    status_key="unknown"
    status_symbol="?"
    status_rendered="${DIM}?${RESET}"
  else
    decoded_entry="$(printf '%s' "$latest_entry" | base64 -d 2>/dev/null)"
    latest="$(jq -r '.name' <<< "$decoded_entry")"
    latest_digest="$(jq -r '.digest // ""' <<< "$decoded_entry")"

    if [[ "$latest" == "$current_tag" ]]; then
      status_key="current"
      status_symbol="✓"
      status_rendered="${GREEN}✓${RESET}"
    else
      status_key="upgrade"
      status_symbol="↑"
      status_rendered="${YELLOW}↑${RESET}"
      upgrades_available=$((upgrades_available + 1))
    fi
  fi

  if [[ "$ONLY_UPGRADES" == true && "$status_key" != "upgrade" ]]; then
    continue
  fi

  results+=("${label}|${display}|${type}|${image}|${current_tag}|${latest}|${status_key}|${status_symbol}|${status_rendered}|${registry}|${latest_digest}")
done

if [[ "$SORT_BY" == "status" ]]; then
  sorted_results=()
  while IFS= read -r row; do
    sorted_results+=("$row")
  done < <(
    printf '%s\n' "${results[@]}" | while IFS='|' read -r label display type image current latest status_key status_symbol status_rendered registry latest_digest; do
      case "$status_key" in
        upgrade) order=1 ;;
        unknown) order=2 ;;
        current) order=3 ;;
        *) order=9 ;;
      esac
      printf '%s|%s\n' "$order" "$label|$display|$type|$image|$current|$latest|$status_key|$status_symbol|$status_rendered|$registry|$latest_digest"
    done | sort -t'|' -k1,1n -k2,2f | cut -d'|' -f2-
  )
else
  sorted_results=("${results[@]}")
fi

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  json_rows=()
  for row in "${sorted_results[@]}"; do
    IFS='|' read -r label display type image current latest status_key status_symbol status_rendered registry latest_digest <<< "$row"
    json_rows+=("$(jq -n \
      --arg label "$label" \
      --arg display "$display" \
      --arg type "$type" \
      --arg image "$image" \
      --arg current "$current" \
      --arg latest "$latest" \
      --arg status "$status_key" \
      --arg registry "$registry" \
      --arg latest_digest "$latest_digest" \
      '{label:$label,display:$display,type:$type,image:$image,current:$current,latest:$latest,status:$status,registry:$registry,latest_digest:$latest_digest}')")
  done

  only_upgrades_json="false"
  if [[ "$ONLY_UPGRADES" == true ]]; then
    only_upgrades_json="true"
  fi

  json_payload_file="$(mktemp)"
  trap 'rm -f "$json_payload_file"' EXIT
  if [[ ${#json_rows[@]} -eq 0 ]]; then
    printf '[]\n' > "$json_payload_file"
  else
    printf '%s\n' "${json_rows[@]}" | jq -s '.' > "$json_payload_file"
  fi

  cache_enabled_json="true"
  [[ "$NO_CACHE" == true ]] && cache_enabled_json="false"

  jq \
    --arg selected_type "${SELECTED_TYPE:-all}" \
    --arg sort_by "$SORT_BY" \
    --argjson only_upgrades "$only_upgrades_json" \
    --argjson timeout "$REQUEST_TIMEOUT" \
    --argjson retries "$REQUEST_RETRIES" \
    --argjson cache_enabled "$cache_enabled_json" \
    --argjson cache_ttl "$CACHE_TTL" \
    --argjson cache_hits "$CACHE_HITS" \
    --argjson cache_misses "$CACHE_MISSES" \
    --arg cache_file "$CACHE_FILE" \
    '{
      selected_type: $selected_type,
      sort_by: $sort_by,
      only_upgrades: $only_upgrades,
      timeout: $timeout,
      retries: $retries,
      cache: {
        enabled: $cache_enabled,
        ttl: $cache_ttl,
        hits: $cache_hits,
        misses: $cache_misses,
        file: $cache_file
      },
      upgrades_available: ([.[] | select(.status == "upgrade")] | length),
      results: .
    }' "$json_payload_file"

  rm -f "$json_payload_file"
  exit 0
fi

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║         Zero Trust Workshop — Container Version Check                ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
printf "${BOLD}%-38s  %-16s  %-16s  %-8s${RESET}\n" "IMAGE" "CURRENT" "LATEST" "STATUS"
echo -e "${DIM}──────────────────────────────────────────────────────────────────────────────${RESET}"

for row in "${sorted_results[@]}"; do
  IFS='|' read -r label display type image current latest status_key status_symbol status_rendered registry latest_digest <<< "$row"
  
  # Shorten MinIO RELEASE tags for display (keep YYYY-MM-DD format)
  if [[ "$current" =~ ^RELEASE\.([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
    current_display="${BASH_REMATCH[1]}"
  else
    current_display="$current"
  fi
  
  if [[ "$latest" =~ ^RELEASE\.([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
    latest_display="${BASH_REMATCH[1]}"
  else
    latest_display="$latest"
  fi
  
  printf "%-38s  %-16s  %-16s  %b\n" "${display:0:37}" "$current_display" "$latest_display" "$status_rendered"
done

echo ""
if [[ $upgrades_available -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All images are up to date.${RESET}"
else
  echo -e "${YELLOW}${BOLD}${upgrades_available} upgrade(s) available.${RESET}"
fi

if [[ "$NO_CACHE" == true ]]; then
  echo -e "${DIM}Cache skipped (--no-cache).${RESET}"
elif [[ $CACHE_HITS -gt 0 ]]; then
  echo -e "${DIM}Cache: ${CACHE_HITS} hit(s), ${CACHE_MISSES} fetch(es) — TTL ${CACHE_TTL}s — ${CACHE_FILE}${RESET}"
  echo -e "${DIM}Run with --no-cache to force a fresh fetch, --cache-clear to reset.${RESET}"
fi
echo ""
