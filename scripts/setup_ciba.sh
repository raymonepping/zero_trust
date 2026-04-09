#!/usr/bin/env bash

set -euo pipefail

VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Colours (match setup_vault.sh style)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_BOLD="\033[1m"; C_DIM="\033[2m"
  C_GREEN="\033[32m"; C_RED="\033[31m"; C_YELLOW="\033[33m"
  C_CYAN="\033[36m";  C_ORANGE="\033[38;5;214m"
else
  C_RESET="" C_BOLD="" C_DIM="" C_GREEN="" C_RED="" C_YELLOW="" C_CYAN="" C_ORANGE=""
fi

ok()   { echo -e "${C_GREEN}✔${C_RESET} $*"; }
err()  { echo -e "${C_RED}✖ $*${C_RESET}" >&2; }
info() { echo -e "${C_CYAN}→${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}⚠${C_RESET} $*"; }
dim()  { echo -e "${C_DIM}$*${C_RESET}"; }
hdr()  { echo -e "\n${C_BOLD}${C_ORANGE}$*${C_RESET}"; }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if [[ -z "${VAULT_ADDR:-}" || -z "${VAULT_TOKEN:-}" ]]; then
  err "VAULT_ADDR and VAULT_TOKEN must be set."
  echo "  export VAULT_ADDR=http://127.0.0.1:8200"
  echo "  export VAULT_TOKEN=<your-token>"
  exit 1
fi

if ! command -v vault >/dev/null 2>&1; then
  err "vault CLI not found on PATH."
  exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
  err "psql is required (PostgreSQL group role creation)."
  exit 1
fi

# ---------------------------------------------------------------------------
# Dependency check: phases 02 + 04 must have been run
# ---------------------------------------------------------------------------
hdr "=== CIBA Setup — Pre-requisite Check ==="

if ! vault secrets list 2>/dev/null | grep -q "^database/"; then
  err "Database secrets engine not found. Run setup_vault.sh --phase 02 first."
  exit 1
fi
ok "Database secrets engine present."

if ! vault auth list 2>/dev/null | grep -q "^jwt/"; then
  err "JWT auth method not found. Run setup_vault.sh --phase 04 first."
  exit 1
fi
ok "JWT auth method present."

if ! vault read database/config/postgres >/dev/null 2>&1; then
  err "Database connection 'postgres' not configured. Run setup_vault.sh --phase 02 first."
  exit 1
fi
ok "Database connection 'postgres' configured."

# ---------------------------------------------------------------------------
# PostgreSQL connection
# ---------------------------------------------------------------------------
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-appdb}"
PGUSER="${PGUSER:-appuser}"
PGPASSWORD="${PGPASSWORD:-apppassword}"
export PGPASSWORD

# ---------------------------------------------------------------------------
# Step 1 — PostgreSQL group role for write access
# ---------------------------------------------------------------------------
hdr "=== Step 1 — PostgreSQL Group Role ==="

info "Creating PostgreSQL group role 'support-write'..."
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" <<'SQL' >/dev/null
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'support-write') THEN
    CREATE ROLE "support-write" NOLOGIN;
  END IF;
END $$;

-- Write access: SELECT + UPDATE on orders table only
-- The agent can read order data and update the status field
GRANT USAGE ON SCHEMA public TO "support-write";
GRANT SELECT, UPDATE ON orders TO "support-write";
SQL
ok "PostgreSQL group role 'support-write' created."

# ---------------------------------------------------------------------------
# Step 2 — Update Vault database connection allowed_roles
# ---------------------------------------------------------------------------
hdr "=== Step 2 — Update Database Connection ==="

info "Adding 'support-write' to allowed_roles on database config 'postgres'..."
vault write database/config/postgres \
  allowed_roles="app-role,viewer-read,support-read,admin-read,support-write" >/dev/null
ok "Database config updated with 'support-write'."

# ---------------------------------------------------------------------------
# Step 3 — Vault database role: support-write
# ---------------------------------------------------------------------------
hdr "=== Step 3 — Vault Database Role ==="

ROLE_ARGS=(db_name=postgres default_ttl="5m" max_ttl="15m")
REVOKE="REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM \"{{name}}\"; REVOKE USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public FROM \"{{name}}\"; DROP OWNED BY \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";"

info "Configuring Vault DB role 'support-write'..."
vault write database/roles/support-write \
  "${ROLE_ARGS[@]}" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE \"support-write\"; GRANT SELECT, UPDATE ON orders TO \"{{name}}\";" \
  revocation_statements="${REVOKE}" \
  >/dev/null
ok "DB role 'support-write' configured."

dim "Note: TTL is intentionally short (5m/15m) — write credentials should be short-lived."

# ---------------------------------------------------------------------------
# Step 4 — Update JWT policy to allow support-write
# ---------------------------------------------------------------------------
hdr "=== Step 4 — Policy Update ==="

info "Updating policy 'zero-trust-jwt-lab' to include 'support-write'..."
vault policy write zero-trust-jwt-lab - <<'EOF'
# Read-scoped credential paths (existing)
path "database/creds/app-role" {
  capabilities = ["read"]
}
path "database/creds/viewer-read" {
  capabilities = ["read"]
}
path "database/creds/support-read" {
  capabilities = ["read"]
}
path "database/creds/admin-read" {
  capabilities = ["read"]
}

# Write-scoped credential path (CIBA — new)
path "database/creds/support-write" {
  capabilities = ["read"]
}

# Token self-management
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}

# Lease management (revocation on rotation)
path "sys/leases/revoke" {
  capabilities = ["update"]
}
path "sys/leases/lookup" {
  capabilities = ["update"]
}
EOF
ok "Policy 'zero-trust-jwt-lab' updated."

# ---------------------------------------------------------------------------
# Step 5 — Smoke tests
# ---------------------------------------------------------------------------
hdr "=== Smoke Tests ==="

info "Requesting dynamic write credential..."
CRED_OUTPUT=$(vault read -format=json database/creds/support-write)
WRITE_USER=$(echo "${CRED_OUTPUT}" | jq -r '.data.username')
WRITE_TTL=$(echo "${CRED_OUTPUT}" | jq -r '.lease_duration')
WRITE_LEASE=$(echo "${CRED_OUTPUT}" | jq -r '.lease_id')
ok "Write credential issued: user=${WRITE_USER}, ttl=${WRITE_TTL}s"

info "Verifying write credential can UPDATE orders..."
WRITE_PASS=$(echo "${CRED_OUTPUT}" | jq -r '.data.password')
UPDATE_RESULT=$(PGPASSWORD="${WRITE_PASS}" psql -h "${PGHOST}" -p "${PGPORT}" -U "${WRITE_USER}" -d "${PGDATABASE}" -t -A -c "UPDATE orders SET status = 'processing' WHERE id = 1 RETURNING id;" 2>&1 || echo "FAILED")
if [[ "${UPDATE_RESULT}" == *"FAILED"* ]]; then
  err "Write credential cannot UPDATE orders. Check PostgreSQL grants."
else
  ok "Write credential can UPDATE orders."
fi

info "Verifying write credential cannot access other tables..."
INSERT_RESULT=$(PGPASSWORD="${WRITE_PASS}" psql -h "${PGHOST}" -p "${PGPORT}" -U "${WRITE_USER}" -d "${PGDATABASE}" -t -A -c "INSERT INTO users (first_name, last_name, email, city, country) VALUES ('test','test','test@test.com','test','test');" 2>&1 || echo "DENIED")
if [[ "${INSERT_RESULT}" == *"DENIED"* ]] || [[ "${INSERT_RESULT}" == *"permission denied"* ]]; then
  ok "Write credential correctly denied INSERT on users table."
else
  warn "Write credential may have unexpected permissions. Verify grants."
fi

info "Revoking test lease..."
vault lease revoke "${WRITE_LEASE}" >/dev/null 2>&1 || true
ok "Test lease revoked."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
hdr "=== CIBA Vault Setup Complete ==="
echo
echo -e "  ${C_CYAN}Vault DB role:${C_RESET}   support-write"
echo -e "  ${C_CYAN}PostgreSQL:${C_RESET}      SELECT + UPDATE on orders"
echo -e "  ${C_CYAN}Default TTL:${C_RESET}     5 minutes"
echo -e "  ${C_CYAN}Max TTL:${C_RESET}         15 minutes"
echo -e "  ${C_CYAN}Policy:${C_RESET}          zero-trust-jwt-lab (updated)"
echo
dim "Next: run setup_ciba_keycloak.sh to configure Keycloak CIBA policy."
echo
ok "Done."
