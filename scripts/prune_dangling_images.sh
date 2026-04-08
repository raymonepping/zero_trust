#!/usr/bin/env bash

set -euo pipefail

APPLY=0

usage() {
  cat <<'EOF'
Usage: ./scripts/prune_dangling_images.sh [--apply]

Lists or removes dangling images only.

Dangling images are untagged images shown as:
  <none>  <none>

By default this is a dry run. Use --apply to actually remove them.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=1
      shift
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

mapfile -t dangling_rows < <(
  docker image ls --filter dangling=true --format '{{.ID}}|{{.CreatedSince}}|{{.Size}}' \
  | tr -d '\r'
)

count="${#dangling_rows[@]}"

if (( count == 0 )); then
  echo "No dangling images found."
  exit 0
fi

if (( APPLY == 0 )); then
  echo "Dry run mode. No images will be deleted."
  echo "Use --apply to remove dangling images."
  echo ""
fi

echo "Found ${count} dangling image(s):"
printf '%-16s %-16s %s\n' "IMAGE ID" "CREATED" "SIZE"
printf '%.0s-' {1..48}
echo ""

for row in "${dangling_rows[@]}"; do
  IFS='|' read -r id created_since size <<< "$row"
  printf '%-16s %-16s %s\n' "$id" "$created_since" "$size"
done

if (( APPLY == 0 )); then
  echo ""
  echo "Dry run complete."
  exit 0
fi

echo ""
for row in "${dangling_rows[@]}"; do
  IFS='|' read -r id _ <<< "$row"
  echo "Removing ${id}"
  docker image rm "$id"
done

echo ""
echo "Dangling image purge complete."
