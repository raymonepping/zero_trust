#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/verify_postgresql.sh [--runtime docker|podman]

Description:
  Verifies that the workshop PostgreSQL volume exists and that the db container
  is mounted to it. If psql is installed locally, it also checks database
  connectivity, roles, and the main workshop tables.

Examples:
  ./scripts/verify_postgresql.sh
  ./scripts/verify_postgresql.sh --runtime podman
EOF
}

info() {
  printf '==> %s\n' "$*"
}

error() {
  printf 'ERR %s\n' "$*" >&2
}

warn() {
  printf 'WARN %s\n' "$*" >&2
}

runtime="${CONTAINER_RUNTIME:-docker}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)
      runtime="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown argument: $1"
      usage >&2
      exit 1
      ;;
  esac
done

case "${runtime}" in
  docker|podman) ;;
  *)
    error "Unsupported runtime '${runtime}'. Use docker or podman."
    exit 1
    ;;
esac

if ! command -v "${runtime}" >/dev/null 2>&1; then
  error "${runtime} CLI is not installed or not on PATH."
  exit 1
fi

compose_cmd=("${runtime}" "compose")

if [[ "${runtime}" == "podman" ]] && ! podman compose version >/dev/null 2>&1; then
  error "podman compose is not available."
  exit 1
fi

info "Compose volumes"
"${compose_cmd[@]}" -f "${repo_root}/docker-compose.yml" config --volumes

db_volume="$("${compose_cmd[@]}" -f "${repo_root}/docker-compose.yml" config --volumes | awk '$0 == "db_data" { print; found=1 } END { if (!found) exit 1 }')"

if [[ -z "${db_volume}" ]]; then
  error "Compose volume 'db_data' not found."
  exit 1
fi

project_name="$(basename "${repo_root}")"

full_volume_name="${project_name}_${db_volume}"
container_name="${project_name}_db"
db_host="${PGHOST:-127.0.0.1}"
db_port="${PGPORT:-5432}"
db_name="${PGDATABASE:-appdb}"
db_user="${PGUSER:-appuser}"
db_password="${PGPASSWORD:-apppassword}"

printf '\n'
info "Matching volume"
"${runtime}" volume ls | grep "${db_volume}" || true

printf '\n'
info "Inspecting volume ${full_volume_name}"
"${runtime}" volume inspect "${full_volume_name}"

printf '\n'
info "Inspecting container mounts for ${container_name}"
if [[ "${runtime}" == "docker" ]]; then
  docker inspect "${container_name}" --format '{{json .Mounts}}'
else
  podman inspect "${container_name}"
fi

if ! command -v psql >/dev/null 2>&1; then
  printf '\n'
  warn "psql not found on PATH. Skipping database login checks."
  exit 0
fi

printf '\n'
info "PostgreSQL connectivity check"
PGPASSWORD="${db_password}" psql \
  -X \
  -P pager=off \
  -h "${db_host}" \
  -p "${db_port}" \
  -U "${db_user}" \
  -d "${db_name}" \
  -c "SELECT current_database() AS database, current_user AS username, version();"

printf '\n'
info "PostgreSQL workshop role check"
PGPASSWORD="${db_password}" psql \
  -X \
  -P pager=off \
  -h "${db_host}" \
  -p "${db_port}" \
  -U "${db_user}" \
  -d "${db_name}" \
  -c "SELECT rolname, rolcanlogin FROM pg_roles WHERE rolname IN ('appuser', 'viewer-read', 'support-read', 'admin-read') ORDER BY rolname;"

printf '\n'
info "PostgreSQL public table inventory"
PGPASSWORD="${db_password}" psql \
  -X \
  -P pager=off \
  -h "${db_host}" \
  -p "${db_port}" \
  -U "${db_user}" \
  -d "${db_name}" \
  -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;"
