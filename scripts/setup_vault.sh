#!/usr/bin/env bash

set -euo pipefail

VERSION="3.0.0"

# ---------------------------------------------------------------------------
# Colours
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
# Phase descriptions
# ---------------------------------------------------------------------------
declare -A PHASE_DESC=(
  [01]="KV v2 secrets engine + static postgres secret         → connector: vault"
  [02]="Database secrets engine + pg group roles + DB roles   → connector: dynamic, approle*, jwt*"
  [03]="AppRole auth + app-policy + zero-trust-app role       → connector: approle, approle-dynamic, approle-rotation"
  [04]="JWT auth (Keycloak) + jwt policy + jwt role           → connector: jwt-rotation, jwt-roles"
  [05]="LDAP auth + ldap-user policy + user mapping           → lab / optional"
  [06]="Audit logging                                         → optional"
  [all]="Run all phases in order (01 → 06)"
)

VALID_PHASES=(01 02 03 04 05 06 all)

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
show_help() {
  echo -e "
${C_BOLD}${C_ORANGE}setup_vault.sh${C_RESET} ${C_DIM}v${VERSION}${C_RESET}

${C_BOLD}DESCRIPTION${C_RESET}
  Configures HashiCorp Vault step-by-step for the zero trust workshop.
  Each phase maps to one or more connector types.

${C_BOLD}USAGE${C_RESET}
  ${C_YELLOW}./scripts/setup_vault.sh${C_RESET} ${C_CYAN}<command> [options]${C_RESET}

${C_BOLD}COMMANDS${C_RESET}
  ${C_YELLOW}--phase${C_RESET} ${C_CYAN}<01|02|03|04|05|06|all>${C_RESET}   Run a specific setup phase
  ${C_YELLOW}--list${C_RESET}                               Show all phases with descriptions
  ${C_YELLOW}--verify${C_RESET}                             Check tooling and Vault connectivity
  ${C_YELLOW}--help${C_RESET}                               Show this help message
  ${C_YELLOW}--version${C_RESET}                            Show script version

${C_BOLD}PHASES${C_RESET}"

  for p in "${VALID_PHASES[@]}"; do
    printf "  ${C_YELLOW}%-6s${C_RESET} %s\n" "$p" "${PHASE_DESC[$p]}"
  done

  echo -e "
${C_BOLD}EXAMPLES${C_RESET}
  ${C_DIM}# Run only KV setup (for vault connector)${C_RESET}
  ${C_YELLOW}./scripts/setup_vault.sh --phase 01${C_RESET}

  ${C_DIM}# Add dynamic DB credentials (for dynamic/approle connectors)${C_RESET}
  ${C_YELLOW}./scripts/setup_vault.sh --phase 02${C_RESET}

  ${C_DIM}# Add AppRole auth (for approle connectors)${C_RESET}
  ${C_YELLOW}./scripts/setup_vault.sh --phase 03${C_RESET}

  ${C_DIM}# Add JWT auth (for jwt-rotation/jwt-roles)${C_RESET}
  ${C_YELLOW}./scripts/setup_vault.sh --phase 04${C_RESET}

  ${C_DIM}# Full workshop setup in one shot${C_RESET}
  ${C_YELLOW}./scripts/setup_vault.sh --phase all${C_RESET}

${C_BOLD}PREREQUISITES${C_RESET}
  ${C_DIM}•${C_RESET} VAULT_ADDR and VAULT_TOKEN must be exported
  ${C_DIM}•${C_RESET} vault CLI must be on PATH
  ${C_DIM}•${C_RESET} psql required for phase 02 (PostgreSQL group roles)
  ${C_DIM}•${C_RESET} Vault must be unsealed before running any phase
"
}

show_version() { echo -e "${C_BOLD}setup_vault.sh${C_RESET} v${VERSION}"; }

list_phases() {
  echo -e "\n${C_BOLD}Available phases:${C_RESET}\n"
  for p in "${VALID_PHASES[@]}"; do
    printf "  ${C_YELLOW}%-6s${C_RESET} %s\n" "$p" "${PHASE_DESC[$p]}"
  done
  echo
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
verify_setup() {
  local status=0
  hdr "=== Vault Environment Verification ==="

  [[ -n "${VAULT_ADDR:-}"  ]] && ok "VAULT_ADDR=${VAULT_ADDR}"  || { err "VAULT_ADDR is missing";  status=1; }
  [[ -n "${VAULT_TOKEN:-}" ]] && ok "VAULT_TOKEN is set"        || { err "VAULT_TOKEN is missing"; status=1; }
  [[ -n "${VAULT_NAMESPACE:-}" ]] \
    && ok "VAULT_NAMESPACE=${VAULT_NAMESPACE}" \
    || ok "VAULT_NAMESPACE not set (fine for local/OSS Vault)"

  command -v vault >/dev/null 2>&1 && ok "vault CLI available" || { err "vault CLI not on PATH"; status=1; }
  command -v psql  >/dev/null 2>&1 && ok "psql available"      || warn "psql not found (needed for phase 02)"

  if [[ "$status" -ne 0 ]]; then echo; err "Pre-flight checks failed."; return "$status"; fi

  vault status >/dev/null 2>&1        && ok "Vault reachable at ${VAULT_ADDR}"    || { err "Vault not reachable"; status=1; }
  vault token lookup >/dev/null 2>&1  && ok "VAULT_TOKEN is valid"                || { err "VAULT_TOKEN invalid"; status=1; }

  echo
  [[ "$status" -eq 0 ]] && ok "Verification complete" || err "Verification failed"
  return "$status"
}

# ---------------------------------------------------------------------------
# Pre-flight (runs before every phase)
# ---------------------------------------------------------------------------
preflight() {
  if [[ -z "${VAULT_ADDR:-}" || -z "${VAULT_TOKEN:-}" ]]; then
    err "VAULT_ADDR and VAULT_TOKEN must be set."
    echo "  export VAULT_ADDR=http://127.0.0.1:8200"
    echo "  export VAULT_TOKEN=<your-token>"
    exit 1
  fi

  if [[ -n "${VAULT_NAMESPACE:-}" ]]; then
    export VAULT_NAMESPACE
    info "Using Vault namespace: ${VAULT_NAMESPACE}"
  fi

  if ! command -v vault >/dev/null 2>&1; then
    err "vault CLI not found on PATH."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Phase 01 — KV v2 + static postgres secret
# ---------------------------------------------------------------------------
phase_01() {
  hdr "=== Phase 01 — KV v2 Secrets Engine ==="
  dim "Connector: vault"

  if vault secrets list | grep -q "^secret/"; then
    ok "KV-v2 already enabled at 'secret/'"
  else
    info "Enabling KV-v2 at 'secret/'..."
    vault secrets enable -path=secret kv-v2
    ok "KV-v2 enabled."
  fi

  if vault kv get secret/postgres >/dev/null 2>&1; then
    ok "Static secret 'secret/postgres' already exists."
  else
    info "Writing static secret to 'secret/postgres'..."
    vault kv put secret/postgres \
      username=appuser \
      password=apppassword \
      host=db \
      port=5432 \
      database=appdb >/dev/null
    ok "Static secret created."
  fi

  ok "Phase 01 complete."
}

# ---------------------------------------------------------------------------
# Phase 02 — Database secrets engine + pg group roles + DB roles
# ---------------------------------------------------------------------------
phase_02() {
  hdr "=== Phase 02 — Database Secrets Engine ==="
  dim "Connector: dynamic, approle, approle-dynamic, approle-rotation, jwt-rotation, jwt-roles"

  if ! command -v psql >/dev/null 2>&1; then
    err "psql is required for phase 02 (PostgreSQL group roles)."
    exit 1
  fi

  PGHOST="${PGHOST:-localhost}"
  PGPORT="${PGPORT:-5432}"
  PGDATABASE="${PGDATABASE:-appdb}"
  PGUSER="${PGUSER:-appuser}"
  PGPASSWORD="${PGPASSWORD:-apppassword}"
  export PGPASSWORD

  # Enable database secrets engine
  if vault secrets list | grep -q "^database/"; then
    ok "Database secrets engine already enabled."
  else
    info "Enabling database secrets engine..."
    vault secrets enable database
    ok "Database secrets engine enabled."
  fi

  # Configure DB connection
  if vault read database/config/postgres >/dev/null 2>&1; then
    info "Updating allowed_roles on 'postgres' config..."
    vault write database/config/postgres \
      allowed_roles="app-role,viewer-read,support-read,admin-read" >/dev/null
    ok "Database config 'postgres' updated."
  else
    info "Configuring database connection 'postgres'..."
    vault write database/config/postgres \
      plugin_name=postgresql-database-plugin \
      allowed_roles="app-role,viewer-read,support-read,admin-read" \
      connection_url="postgresql://{{username}}:{{password}}@db:5432/appdb?sslmode=disable" \
      username="appuser" \
      password="apppassword" >/dev/null
    ok "Database connection configured."
  fi

  # PostgreSQL group roles + grants
  info "Ensuring PostgreSQL group roles and grants..."
  psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" <<'SQL' >/dev/null
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'viewer-read') THEN
    CREATE ROLE "viewer-read" NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'support-read') THEN
    CREATE ROLE "support-read" NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'admin-read') THEN
    CREATE ROLE "admin-read" NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO "viewer-read", "support-read", "admin-read";
GRANT SELECT ON users TO "viewer-read";
GRANT SELECT ON users, orders, preferences, training, tickets, projects TO "support-read";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "admin-read";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "admin-read";
SQL
  ok "PostgreSQL group roles prepared."

  # Vault DB roles
  local ROLE_ARGS=(db_name=postgres default_ttl="1h" max_ttl="24h")
  local REVOKE="REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM \"{{name}}\"; REVOKE USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public FROM \"{{name}}\"; DROP OWNED BY \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";"

  info "Configuring Vault DB role 'app-role'..."
  vault write database/roles/app-role \
    "${ROLE_ARGS[@]}" \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\"; GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\";" \
    >/dev/null
  ok "DB role 'app-role' configured."

  info "Configuring Vault DB role 'viewer-read'..."
  vault write database/roles/viewer-read \
    "${ROLE_ARGS[@]}" \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE \"viewer-read\"; GRANT SELECT ON users TO \"{{name}}\"; GRANT SELECT ON orders TO \"{{name}}\";" \
    revocation_statements="${REVOKE}" \
    >/dev/null
  ok "DB role 'viewer-read' configured."

  info "Configuring Vault DB role 'support-read'..."
  vault write database/roles/support-read \
    "${ROLE_ARGS[@]}" \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE \"support-read\"; GRANT SELECT ON users, orders, preferences, training, tickets, projects TO \"{{name}}\";" \
    revocation_statements="${REVOKE}" \
    >/dev/null
  ok "DB role 'support-read' configured."

  info "Configuring Vault DB role 'admin-read'..."
  vault write database/roles/admin-read \
    "${ROLE_ARGS[@]}" \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE \"admin-read\"; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\"; GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\";" \
    revocation_statements="${REVOKE}" \
    >/dev/null
  ok "DB role 'admin-read' configured."

  echo
  info "Smoke test — dynamic credential for 'app-role':"
  vault read database/creds/app-role

  ok "Phase 02 complete."
}

# ---------------------------------------------------------------------------
# Phase 03 — AppRole auth
# ---------------------------------------------------------------------------
phase_03() {
  hdr "=== Phase 03 — AppRole Auth Method ==="
  dim "Connector: approle, approle-dynamic, approle-rotation"

  if vault auth list | grep -q "^approle/"; then
    ok "AppRole auth already enabled."
  else
    info "Enabling AppRole auth..."
    vault auth enable approle
    ok "AppRole auth enabled."
  fi

  info "Writing policy 'app-policy'..."
  vault policy write app-policy - <<'EOF'
path "database/creds/app-role" {
  capabilities = ["read"]
}
path "secret/data/postgres" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
EOF
  ok "Policy 'app-policy' written."

  if vault read auth/approle/role/zero-trust-app >/dev/null 2>&1; then
    ok "AppRole role 'zero-trust-app' already exists."
  else
    info "Creating AppRole role 'zero-trust-app'..."
    vault write auth/approle/role/zero-trust-app \
      token_policies="app-policy" \
      token_ttl=1h \
      token_max_ttl=4h \
      secret_id_ttl=0 \
      secret_id_num_uses=0 >/dev/null
    ok "AppRole role created."
  fi

  local ROLE_ID SECRET_ID
  ROLE_ID=$(vault read -field=role_id auth/approle/role/zero-trust-app/role-id)
  SECRET_ID=$(vault write -field=secret_id -force auth/approle/role/zero-trust-app/secret-id)

  echo
  hdr "=== AppRole Credentials ==="
  echo -e "Add to your ${C_CYAN}.env${C_RESET}:"
  echo ""
  echo "  VAULT_ROLE_ID=${ROLE_ID}"
  echo "  VAULT_SECRET_ID=${SECRET_ID}"
  echo ""
  warn "Secret ID shown once — regenerate with:"
  dim "  vault write -force auth/approle/role/zero-trust-app/secret-id"

  echo
  info "Smoke test — AppRole login:"
  vault write auth/approle/login role_id="${ROLE_ID}" secret_id="${SECRET_ID}" \
    | grep -E "token |token_policies|token_ttl"

  ok "Phase 03 complete."
}

# ---------------------------------------------------------------------------
# Phase 04 — JWT auth (Keycloak)
# ---------------------------------------------------------------------------
phase_04() {
  hdr "=== Phase 04 — JWT Auth Method (Keycloak) ==="
  dim "Connector: jwt-rotation, jwt-roles"

  KEYCLOAK_ADDR="${KEYCLOAK_ADDR:-http://keycloak:8080}"
  KEYCLOAK_REALM="${KEYCLOAK_REALM:-zero-trust}"
  KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER:-${KEYCLOAK_ADDR}/realms/${KEYCLOAK_REALM}}"
  KEYCLOAK_TOKEN_AUDIENCE="${KEYCLOAK_TOKEN_AUDIENCE:-account}"

  if vault auth list | grep -q "^jwt/"; then
    ok "JWT auth already enabled."
  else
    info "Enabling JWT auth..."
    vault auth enable jwt
    ok "JWT auth enabled."
  fi

  info "Configuring JWT auth (Keycloak JWKS)..."
  vault write auth/jwt/config \
    jwks_url="${KEYCLOAK_ADDR}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs" \
    bound_issuer="${KEYCLOAK_ISSUER}" >/dev/null
  ok "JWT auth configured."

  info "Writing policy 'zero-trust-jwt-lab'..."
  vault policy write zero-trust-jwt-lab - <<'EOF'
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
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
path "sys/leases/lookup" {
  capabilities = ["update"]
}
EOF
  ok "Policy 'zero-trust-jwt-lab' written."

  info "Writing JWT role 'zero-trust-jwt-lab'..."
  vault write auth/jwt/role/zero-trust-jwt-lab \
    role_type="jwt" \
    bound_audiences="${KEYCLOAK_TOKEN_AUDIENCE}" \
    bound_issuer="${KEYCLOAK_ISSUER}" \
    user_claim="email" \
    token_policies="zero-trust-jwt-lab" \
    token_ttl="15m" >/dev/null
  ok "JWT role 'zero-trust-jwt-lab' written."

  echo
  info "Smoke test — JWT auth config:"
  vault read auth/jwt/config | grep -E "jwks_url|bound_issuer"

  echo
  dim "To test JWT login manually from inside the Docker network:"
  dim "  vault write auth/jwt/login role=zero-trust-jwt-lab \\"
  dim "    jwt=\$(curl -s -X POST \"${KEYCLOAK_ADDR}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token\" \\"
  dim "      -H \"Content-Type: application/x-www-form-urlencoded\" \\"
  dim "      -d \"grant_type=password&client_id=backend&username=repping&password=password&scope=openid\" \\"
  dim "      --data-urlencode \"client_secret=\${KEYCLOAK_CLIENT_SECRET}\" | jq -r '.access_token')"

  ok "Phase 04 complete."
}

# ---------------------------------------------------------------------------
# Phase 05 — LDAP auth
# ---------------------------------------------------------------------------
phase_05() {
  hdr "=== Phase 05 — LDAP Auth Method ==="
  dim "Optional lab exercise"

  if vault auth list | grep -q "^ldap/"; then
    ok "LDAP auth already enabled."
  else
    info "Enabling LDAP auth..."
    vault auth enable ldap
    ok "LDAP auth enabled."
  fi

  info "Configuring LDAP connection..."
  vault write auth/ldap/config \
    url="ldap://openldap:389" \
    userdn="ou=people,dc=my,dc=org" \
    groupdn="ou=groups,dc=my,dc=org" \
    binddn="cn=admin,dc=my,dc=org" \
    bindpass="admin" \
    userattr="uid" \
    groupfilter="(|(memberUid={{.Username}})(member={{.UserDN}})(uniqueMember={{.UserDN}}))" \
    groupattr="cn" \
    insecure_tls=true >/dev/null
  ok "LDAP connection configured."

  info "Writing policy 'ldap-user'..."
  vault policy write ldap-user - <<'EOF'
path "secret/data/postgres" {
  capabilities = ["read"]
}
path "secret/metadata/postgres" {
  capabilities = ["read", "list"]
}
EOF
  ok "Policy 'ldap-user' written."

  info "Mapping LDAP user 'repping' → 'ldap-user' policy..."
  vault write auth/ldap/users/repping policies="ldap-user" >/dev/null
  ok "User 'repping' mapped."

  echo
  info "Smoke test — LDAP config:"
  vault read auth/ldap/config | grep -E "url|userdn|groupdn|userattr"

  dim "To test LDAP login manually:"
  dim "  vault login -method=ldap username=repping"

  ok "Phase 05 complete."
}

# ---------------------------------------------------------------------------
# Phase 06 — Audit logging
# ---------------------------------------------------------------------------
phase_06() {
  hdr "=== Phase 06 — Audit Logging ==="
  dim "Optional but recommended"

  if vault audit list | grep -q "^file/"; then
    ok "File audit device already enabled."
  else
    info "Enabling file audit at /vault/audit/vault-audit.log..."
    vault audit enable file file_path=/vault/audit/vault-audit.log \
      log_raw=false \
      hmac_accessor=true >/dev/null
    ok "Audit logging enabled."
  fi

  ok "Phase 06 complete."
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
PHASE=""

if [[ $# -eq 0 ]]; then show_help; exit 1; fi

case "$1" in
  --phase)
    [[ -z "${2:-}" ]] && { err "Missing phase. Run --list to see options."; exit 1; }
    PHASE="$2"
    valid=false
    for p in "${VALID_PHASES[@]}"; do [[ "$p" == "$PHASE" ]] && valid=true && break; done
    [[ "$valid" == false ]] && { err "Unknown phase '${PHASE}'. Valid: ${VALID_PHASES[*]}"; exit 1; }
    ;;
  --list)    list_phases; exit 0 ;;
  --verify)  verify_setup; exit $? ;;
  --help|-h) show_help; exit 0 ;;
  --version) show_version; exit 0 ;;
  *)
    err "Unknown option: $1"
    echo -e "Run ${C_YELLOW}./scripts/setup_vault.sh --help${C_RESET} for usage."
    exit 1
    ;;
esac

preflight

case "$PHASE" in
  01)  phase_01 ;;
  02)  phase_02 ;;
  03)  phase_03 ;;
  04)  phase_04 ;;
  05)  phase_05 ;;
  06)  phase_06 ;;
  all)
    phase_01
    phase_02
    phase_03
    phase_04
    phase_05
    phase_06
    hdr "=== All phases complete ==="
    ;;
esac
