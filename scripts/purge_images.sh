#!/usr/bin/env bash

set -euo pipefail

KEEP_COUNT=3
APPLY=0
RUNTIME="auto"
EFFECTIVE_RUNTIME=""

TARGET_REPOS=(
  "repping/zero-trust-backend"
  "repping/zero-trust-frontend"
)

usage() {
  cat <<'EOF'
Usage: ./scripts/purge_images.sh [--apply] [--keep N] [--runtime docker|podman|auto]

Keeps the latest N version tags for:
  - repping/zero-trust-backend
  - repping/zero-trust-frontend

By default this is a dry run. Use --apply to actually remove old tags.
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
    --apply)
      APPLY=1
      shift
      ;;
    --keep)
      KEEP_COUNT="${2:-}"
      if [[ -z "$KEEP_COUNT" || ! "$KEEP_COUNT" =~ ^[0-9]+$ || "$KEEP_COUNT" -lt 1 ]]; then
        echo "Invalid value for --keep: ${2:-<missing>}" >&2
        exit 1
      fi
      shift 2
      ;;
    --runtime)
      RUNTIME="${2:-}"
      if [[ -z "${RUNTIME}" ]]; then
        echo "Missing value for --runtime" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

resolve_runtime

if ! command -v "${EFFECTIVE_RUNTIME}" >/dev/null 2>&1; then
  echo "ERROR: ${EFFECTIVE_RUNTIME} CLI is not installed or not on PATH" >&2
  exit 1
fi

if (( APPLY == 0 )); then
  echo "Dry run mode. No images will be deleted."
  echo "Use --apply to remove old tags."
  echo "Runtime: ${EFFECTIVE_RUNTIME}"
  echo ""
fi

for repo in "${TARGET_REPOS[@]}"; do
  echo "== ${repo} =="

  mapfile -t tags < <(
    "${EFFECTIVE_RUNTIME}" image ls "$repo" --format '{{.Tag}}' \
    | tr -d '\r' \
    | awk 'NF && $0 != "<none>"' \
    | sort -u -V
  )

  total="${#tags[@]}"
  if (( total == 0 )); then
    echo "No local tags found."
    echo ""
    continue
  fi

  if (( total <= KEEP_COUNT )); then
    echo "Found ${total} tag(s). Nothing to remove."
    printf 'Keeping: %s\n' "${tags[*]}"
    echo ""
    continue
  fi

  keep_start=$(( total - KEEP_COUNT ))
  keep_tags=( "${tags[@]:keep_start}" )
  remove_tags=( "${tags[@]:0:keep_start}" )

  printf 'Keeping newest %d tag(s): %s\n' "$KEEP_COUNT" "${keep_tags[*]}"
  printf 'Removing %d older tag(s): %s\n' "${#remove_tags[@]}" "${remove_tags[*]}"

  if (( APPLY == 1 )); then
    for tag in "${remove_tags[@]}"; do
      image_ref="${repo}:${tag}"
      echo "Removing ${image_ref}"
      "${EFFECTIVE_RUNTIME}" image rm "${image_ref}"
    done
  fi

  echo ""
done

if (( APPLY == 0 )); then
  echo "Dry run complete."
else
  echo "Purge complete."
fi
