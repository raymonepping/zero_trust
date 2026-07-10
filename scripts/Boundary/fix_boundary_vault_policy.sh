#!/bin/bash
set -e

# Fix Boundary Vault Integration - Create proper policy and token
# This script creates a Vault policy that allows Boundary to sign SSH certificates

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "=========================================="
echo "  Fix Boundary Vault Integration"
echo "=========================================="
echo ""

# Configuration
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN="${VAULT_TOKEN:-hvs.REPLACE_WITH_YOUR_TOKEN}"
export BOUNDARY_ADDR="http://localhost:9200"
VAULT_CRED_STORE="csvlt_s1WV97fBZS"
AUTH_METHOD_ID="ampw_8RfTaBwDa2"
BOUNDARY_PASSWORD="${1:-Password123!}"

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

# Step 2: Create a token for Boundary with the policy
echo -e "${BLUE}==> Step 2: Creating Vault token for Boundary${NC}"
BOUNDARY_TOKEN=$(vault token create \
    -policy=boundary-controller \
    -ttl=720h \
    -renewable=true \
    -format=json | jq -r '.auth.client_token')

if [ -z "$BOUNDARY_TOKEN" ]; then
    echo -e "${RED}✗ Failed to create Boundary token${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Boundary token created${NC}"
echo -e "${YELLOW}Token: ${BOUNDARY_TOKEN}${NC}"
echo ""

# Step 3: Authenticate to Boundary
echo -e "${BLUE}==> Step 3: Authenticating to Boundary${NC}"
# Use printf to pipe password to boundary authenticate
if printf "%s\n" "${BOUNDARY_PASSWORD}" | boundary authenticate password \
    -auth-method-id=${AUTH_METHOD_ID} \
    -login-name=admin > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Authenticated to Boundary${NC}"
else
    echo -e "${RED}✗ Failed to authenticate to Boundary${NC}"
    echo -e "${YELLOW}Please ensure:${NC}"
    echo "  • Boundary is running (podman ps | grep boundary)"
    echo "  • Admin password is correct (default: Password123!)"
    echo "  • Auth method ID is correct: ${AUTH_METHOD_ID}"
    echo ""
    echo -e "${YELLOW}Trying alternative authentication method...${NC}"
    # Try with expect or direct password flag if available
    if boundary authenticate password \
        -auth-method-id=${AUTH_METHOD_ID} \
        -login-name=admin \
        -password="env://BOUNDARY_PASSWORD" 2>&1 | grep -q "successfully"; then
        echo -e "${GREEN}✓ Authenticated to Boundary (alternative method)${NC}"
    else
        echo -e "${RED}✗ Authentication failed. Please authenticate manually:${NC}"
        echo "  boundary authenticate password -auth-method-id=${AUTH_METHOD_ID} -login-name=admin"
        exit 1
    fi
fi
echo ""

# Step 4: Update Boundary credential store with new token
echo -e "${BLUE}==> Step 4: Updating Boundary Vault credential store${NC}"
boundary credential-stores update vault \
    -id=${VAULT_CRED_STORE} \
    -vault-token=${BOUNDARY_TOKEN} \
    -vault-address=http://vault:8200

echo -e "${GREEN}✓ Credential store updated with new token${NC}"
echo ""

# Step 5: Verify the credential store
echo -e "${BLUE}==> Step 5: Verifying credential store${NC}"
boundary credential-stores read -id=${VAULT_CRED_STORE}
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}  Fix Complete! ✓${NC}"
echo "=========================================="
echo ""
echo "Boundary can now use Vault to sign SSH certificates!"
echo ""
echo -e "${YELLOW}Important:${NC}"
echo "  • The Vault token has a 720h (30 day) TTL"
echo "  • Token is renewable - Boundary will auto-renew it"
echo "  • Policy 'boundary-controller' grants SSH signing permissions"
echo ""
echo "Next steps:"
echo "  1. Test SSH connection:"
echo "     boundary connect ssh -target-id=<your-target-id>"
echo ""
echo "  2. If token expires, re-run this script to create a new one"
echo ""

# Made with Bob