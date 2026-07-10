#!/bin/bash
set -e

# Update Boundary Vault Credential Store Token
# Run this after you've already authenticated to Boundary

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "=========================================="
echo "  Update Boundary Vault Token"
echo "=========================================="
echo ""

# Configuration
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN="${VAULT_TOKEN:-hvs.REPLACE_WITH_YOUR_TOKEN}"
export BOUNDARY_ADDR="http://localhost:9200"
VAULT_CRED_STORE="csvlt_s1WV97fBZS"

# Check if already authenticated to Boundary
echo -e "${BLUE}==> Checking Boundary authentication${NC}"
if ! boundary scopes list > /dev/null 2>&1; then
    echo -e "${RED}✗ Not authenticated to Boundary${NC}"
    echo -e "${YELLOW}Please authenticate first:${NC}"
    echo "  boundary authenticate password -auth-method-id=ampw_8RfTaBwDa2 -login-name=admin"
    exit 1
fi
echo -e "${GREEN}✓ Already authenticated to Boundary${NC}"
echo ""

# Step 1: Create Vault policy for Boundary
echo -e "${BLUE}==> Step 1: Creating Vault policy for Boundary${NC}"
vault policy write boundary-controller - <<EOF
# Allow Boundary to sign SSH certificates
path "ssh/sign/boundary-ssh" {
  capabilities = ["create", "update"]
}

# Allow Boundary to read SSH CA public key
path "ssh/config/ca" {
  capabilities = ["read"]
}

# Allow Boundary to revoke leases (required for credential cleanup)
path "sys/leases/revoke" {
  capabilities = ["update"]
}

# Allow token self-lookup and renewal
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
EOF
echo -e "${GREEN}✓ Policy 'boundary-controller' created${NC}"
echo ""

# Step 2: Create an ORPHAN PERIODIC token for Boundary with the policy
echo -e "${BLUE}==> Step 2: Creating Vault orphan periodic token for Boundary${NC}"
echo -e "${YELLOW}Note: Boundary requires an orphan periodic token${NC}"
BOUNDARY_TOKEN=$(vault token create \
    -orphan \
    -period=720h \
    -policy=boundary-controller \
    -format=json | jq -r '.auth.client_token')

if [ -z "$BOUNDARY_TOKEN" ]; then
    echo -e "${RED}✗ Failed to create Boundary token${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Boundary token created${NC}"
echo -e "${YELLOW}Token: ${BOUNDARY_TOKEN}${NC}"
echo ""

# Step 3: Update Boundary credential store with new token
echo -e "${BLUE}==> Step 3: Updating Boundary Vault credential store${NC}"
boundary credential-stores update vault \
    -id=${VAULT_CRED_STORE} \
    -vault-token=${BOUNDARY_TOKEN} \
    -vault-address=http://vault:8200

echo -e "${GREEN}✓ Credential store updated with new token${NC}"
echo ""

# Step 4: Verify the credential store
echo -e "${BLUE}==> Step 4: Verifying credential store${NC}"
boundary credential-stores read -id=${VAULT_CRED_STORE}
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}  Update Complete! ✓${NC}"
echo "=========================================="
echo ""
echo "Boundary can now use Vault to sign SSH certificates!"
echo ""
echo -e "${YELLOW}Important:${NC}"
echo "  • The Vault token is an orphan periodic token"
echo "  • Period: 720h (30 days) - auto-renews indefinitely"
echo "  • Policy 'boundary-controller' grants SSH signing permissions"
echo ""
echo "Next steps:"
echo "  1. Test SSH connection:"
echo "     boundary connect ssh -target-id=<your-target-id>"
echo ""
echo "  2. If token expires, re-run this script to create a new one"
echo ""

# Made with Bob