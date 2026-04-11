#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/verify_postgresql.sh [--runtime docker|podman]

Description:
  Verifies that the workshop PostgreSQL volume exists and that the db container
  is mounted to it. If psql is installed locally, it also checks database
  connectivity, roles, table presence, row counts, and RLS policies.

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

clean_compose_output() {
  sed -E $'s/\x1B\\[[0-9;]*[[:alpha:]]//g' | grep -v 'Executing external compose provider'
}

if [[ "${runtime}" == "podman" ]] && ! podman compose version >/dev/null 2>&1; then
  error "podman compose is not available."
  exit 1
fi

# Hardcode the compose project name — deriving it from the directory name breaks
# when the repo is cloned to a differently named folder.
COMPOSE_PROJECT="zero_trust"

info "Compose volumes"
compose_volumes="$("${compose_cmd[@]}" -f "${repo_root}/docker-compose.yml" config --volumes 2>&1 | clean_compose_output)"
printf '%s\n' "${compose_volumes}"

db_volume="$(printf '%s\n' "${compose_volumes}" | awk '$0 == "db_data" { print; found=1 } END { if (!found) exit 1 }')"

if [[ -z "${db_volume}" ]]; then
  error "Compose volume 'db_data' not found."
  exit 1
fi

full_volume_name="${COMPOSE_PROJECT}_${db_volume}"
container_name="${COMPOSE_PROJECT}_db"
db_host="${PGHOST:-127.0.0.1}"
db_port="${PGPORT:-5432}"
db_name="${PGDATABASE:-appdb}"
db_user="${PGUSER:-appuser}"
db_password="${PGPASSWORD:-apppassword}"

printf '\n'
info "Matching volume"
"${runtime}" volume ls | grep "${full_volume_name}" || warn "Volume ${full_volume_name} not found — stack may not be running"

printf '\n'
info "Inspecting volume ${full_volume_name}"
"${runtime}" volume inspect "${full_volume_name}" | jq '.[0] | {Name, Driver, Mountpoint, CreatedAt}'

printf '\n'
info "Inspecting container mounts for ${container_name}"
"${runtime}" inspect "${container_name}" --format '{{json .Mounts}}' | jq '.[] | {Type, Name, Destination}'

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
  -c "SELECT rolname, rolcanlogin FROM pg_roles WHERE rolname IN ('appuser', 'viewer-read', 'support-read', 'support-write', 'admin-read') ORDER BY rolname;"

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

printf '\n'
info "Row counts (confirms seed_db.sh ran)"
PGPASSWORD="${db_password}" psql \
  -X \
  -P pager=off \
  -h "${db_host}" \
  -p "${db_port}" \
  -U "${db_user}" \
  -d "${db_name}" \
  -c "SELECT relname AS table, n_live_tup AS rows FROM pg_stat_user_tables ORDER BY relname;"

printf '\n'
info "RLS policy check"
PGPASSWORD="${db_password}" psql \
  -X \
  -P pager=off \
  -h "${db_host}" \
  -p "${db_port}" \
  -U "${db_user}" \
  -d "${db_name}" \
  -c "SELECT tablename, policyname, roles, cmd FROM pg_policies ORDER BY tablename, policyname;"
