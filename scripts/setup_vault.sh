#!/bin/bash

# ==========================================
# Pre-flight Checks
# ==========================================

# Ensure VAULT_ADDR and VAULT_TOKEN are set in the environment
if [ -z "$VAULT_ADDR" ] || [ -z "$VAULT_TOKEN" ]; then
  echo "❌ Error: VAULT_ADDR and VAULT_TOKEN environment variables must be set."
  echo "Example:"
  echo "  export VAULT_ADDR=http://127.0.0.1:8200"
  echo "  export VAULT_TOKEN=hvs.yourtokenhere"
  exit 1
fi

echo "=== Starting Vault Configuration ==="

# ==========================================
# 1. KV-V2 Secrets Engine
# ==========================================

if vault secrets list | grep -q "^secret/"; then
  echo "✅ KV-v2 secrets engine already enabled at 'secret/'."
else
  echo "⏳ Enabling KV-v2 secrets engine at 'secret/'..."
  vault secrets enable -path=secret kv-v2
fi

if vault kv get secret/postgres > /dev/null 2>&1; then
  echo "✅ Static secret 'secret/postgres' already exists."
else
  echo "⏳ Writing static secret to 'secret/postgres'..."
  vault kv put secret/postgres \
    username=appuser \
    password=apppassword \
    host=db \
    port=5432 \
    database=appdb > /dev/null
  echo "✅ Static secret created."
fi

# ==========================================
# 2. Database Secrets Engine
# ==========================================

if vault secrets list | grep -q "^database/"; then
  echo "✅ Database secrets engine already enabled at 'database/'."
else
  echo "⏳ Enabling database secrets engine at 'database/'..."
  vault secrets enable database
fi

# ==========================================
# 3. Database Configuration
# ==========================================

if vault read database/config/postgres > /dev/null 2>&1; then
  echo "✅ Database configuration 'postgres' already exists."
else
  echo "⏳ Configuring database connection 'postgres'..."
  vault write database/config/postgres \
    plugin_name=postgresql-database-plugin \
    allowed_roles="app-role" \
    connection_url="postgresql://{{username}}:{{password}}@db:5432/appdb?sslmode=disable" \
    username="appuser" \
    password="apppassword" > /dev/null
  echo "✅ Database connection configured."
fi

# ==========================================
# 4. Database Roles
# ==========================================

if vault read database/roles/app-role > /dev/null 2>&1; then
  echo "✅ Database role 'app-role' already exists."
else
  echo "⏳ Configuring database role 'app-role'..."
  vault write database/roles/app-role \
    db_name=postgres \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\"; GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h" > /dev/null
  echo "✅ Database role configured."
fi

# ==========================================
# 5. AppRole Auth Method
# ==========================================

if vault auth list | grep -q "^approle/"; then
  echo "✅ AppRole auth method already enabled."
else
  echo "⏳ Enabling AppRole auth method..."
  vault auth enable approle
fi

# ==========================================
# 6. Vault Policy for AppRole
# ==========================================

if vault policy read app-policy > /dev/null 2>&1; then
  echo "✅ Policy 'app-policy' already exists."
else
  echo "⏳ Writing policy 'app-policy'..."
  vault policy write app-policy - <<'EOF'
# Allow reading dynamic database credentials
path "database/creds/app-role" {
  capabilities = ["read"]
}

# Allow reading KV postgres secret
path "secret/data/postgres" {
  capabilities = ["read"]
}

# Allow looking up and renewing own token
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
EOF
  echo "✅ Policy created."
fi

# ==========================================
# 7. AppRole Role
# ==========================================

if vault read auth/approle/role/zero-trust-app > /dev/null 2>&1; then
  echo "✅ AppRole role 'zero-trust-app' already exists."
else
  echo "⏳ Creating AppRole role 'zero-trust-app'..."
  vault write auth/approle/role/zero-trust-app \
    token_policies="app-policy" \
    token_ttl=1h \
    token_max_ttl=4h \
    secret_id_ttl=0 \
    secret_id_num_uses=0 > /dev/null
  echo "✅ AppRole role created."
fi

# ==========================================
# 8. Output Role ID and Secret ID
# ==========================================

ROLE_ID=$(vault read -field=role_id auth/approle/role/zero-trust-app/role-id)
SECRET_ID=$(vault write -field=secret_id -force auth/approle/role/zero-trust-app/secret-id)

echo -e "\n=== AppRole Credentials ==="
echo "Add these to your .env or docker-compose environment:"
echo ""
echo "  VAULT_ROLE_ID=${ROLE_ID}"
echo "  VAULT_SECRET_ID=${SECRET_ID}"
echo ""
echo "⚠️  Secret ID is single-use-friendly — regenerate with:"
echo "  vault write -force auth/approle/role/zero-trust-app/secret-id"

# ==========================================
# 9. Validation & Testing
# ==========================================

echo -e "\n=== Validation ==="
echo "Testing dynamic credentials generation for 'app-role':"
echo "------------------------------------------------------"
vault read database/creds/app-role

echo -e "\nTesting AppRole login:"
echo "----------------------"
vault write auth/approle/login role_id="${ROLE_ID}" secret_id="${SECRET_ID}" | grep -E "token |token_policies|token_ttl"

echo -e "\nTesting application credentials endpoint (localhost:3000):"
echo "--------------------------------------------------------"
curl -s http://localhost:3000/credentials || echo "⚠️ Failed to reach http://localhost:3000/credentials. (Is the app running?)"

echo -e "\n=== Setup Complete ==="