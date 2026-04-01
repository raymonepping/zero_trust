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

  echo "Building ${FULL_IMAGE}"
  docker build --load -t "${FULL_IMAGE}" "${PATHCTX}"

  echo "Pushing ${FULL_IMAGE}"
  docker push "${FULL_IMAGE}"

  echo "Done ${FULL_IMAGE}"
  echo
done
