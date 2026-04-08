#!/usr/bin/env bash

set -euo pipefail

VERSION="${1:-1.0.0}"
DOCKER_USER="${2:-repping}"

COMPOSE_FILE="$(cd "$(dirname "$0")/.." && pwd)/docker-compose.yml"

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

  echo "Updating ${NAME} image tag in docker-compose.yml"
  sed -i.bak "s|image: ${DOCKER_USER}/${NAME}:.*|image: ${FULL_IMAGE}|" "${COMPOSE_FILE}"
  rm -f "${COMPOSE_FILE}.bak"

  echo "Done ${FULL_IMAGE}"
  echo
done

echo "docker-compose.yml updated to version ${VERSION}"
