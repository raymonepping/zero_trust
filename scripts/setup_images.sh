#!/usr/bin/env bash

set -euo pipefail

VERSION="${1:-1.0.0}"
DOCKER_USER="${2:-repping}"

IMAGES=(
  "zero-trust-backend:./backend"
  "zero-trust-frontend:./frontend"
)

for item in "${IMAGES[@]}"; do
  NAME="${item%%:*}"
  PATHCTX="${item##*:}"

  FULL_IMAGE="${DOCKER_USER}/${NAME}:${VERSION}"

  echo "Building and pushing ${FULL_IMAGE}"
  docker build \
    --no-cache \
    --platform linux/amd64,linux/arm64 \
    --push \
    -t "${FULL_IMAGE}" \
    "${PATHCTX}"

  echo "Done ${FULL_IMAGE}"
  echo
done
