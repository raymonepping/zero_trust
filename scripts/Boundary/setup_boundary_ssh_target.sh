#!/bin/bash
set -e

# Setup Boundary SSH Target with Vault Credential Injection
# Creates a target for SSH access to Ubuntu container using Vault-managed credentials

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "=========================================="
echo "  Boundary SSH Target Setup"
echo "=========================================="
echo ""

# Configuration
export BOUNDARY_ADDR="http://localhost:9200"
TARGET_NAME="boundary-ssh-ubuntu"
SSH_IP="10.89.3.93"
SSH_PORT="22"
SSH_USER="danielle"
BOUNDARY_PASSWORD="${1:-Password123!}"

# Boundary Resource IDs (from existing setup)
ORG_SCOPE="o_7a1VQLLGUg"
PROJECT_SCOPE="p_vTsmEn4gLN"
VAULT_CRED_STORE="csvlt_s1WV97fBZS"

# Authenticate to Boundary
echo -e "${BLUE}==> Authenticating to Boundary${NC}"

# Write password to temp file for boundary CLI
echo "${BOUNDARY_PASSWORD}" > /tmp/boundary_pass.txt

boundary authenticate password \
    -auth-method-id=ampw_8RfTaBwDa2 \
    -login-name=admin \
    -password=file:///tmp/boundary_pass.txt > /dev/null 2>&1

AUTH_RESULT=$?
rm -f /tmp/boundary_pass.txt

if [ $AUTH_RESULT -ne 0 ]; then
    echo -e "${RED}✗ Authentication failed${NC}"
    echo "Usage: $0 [boundary-admin-password]"
    echo "Default password: Password123!"
    exit 1
fi

echo -e "${GREEN}✓ Authenticated to Boundary${NC}"
echo ""

echo -e "${BLUE}==> Step 1: Using existing Boundary scopes${NC}"
echo -e "${GREEN}✓ Org Scope: ${ORG_SCOPE}${NC}"
echo -e "${GREEN}✓ Project Scope: ${PROJECT_SCOPE}${NC}"
echo -e "${GREEN}✓ Vault Credential Store: ${VAULT_CRED_STORE}${NC}"
echo ""

# Step 2: Get or create host catalog
echo -e "${BLUE}==> Step 2: Getting or creating host catalog${NC}"
HOST_CATALOG=$(boundary host-catalogs list -scope-id=${PROJECT_SCOPE} -format=json | jq -r '.items[] | select(.name=="ubuntu-hosts") | .id' | head -1)

if [ -z "$HOST_CATALOG" ]; then
    HOST_CATALOG=$(boundary host-catalogs create static \
        -scope-id=${PROJECT_SCOPE} \
        -name="ubuntu-hosts" \
        -description="Ubuntu SSH hosts" \
        -format=json | jq -r '.item.id')
    echo -e "${GREEN}✓ Host Catalog Created: ${HOST_CATALOG}${NC}"
else
    echo -e "${YELLOW}✓ Host Catalog Found: ${HOST_CATALOG}${NC}"
fi
echo ""

# Step 3: Get or create host
echo -e "${BLUE}==> Step 3: Getting or creating host${NC}"
HOST=$(boundary hosts list -host-catalog-id=${HOST_CATALOG} -format=json | jq -r '.items[] | select(.name=="ubuntu-ssh-host") | .id' | head -1)

if [ -z "$HOST" ]; then
    HOST=$(boundary hosts create static \
        -host-catalog-id=${HOST_CATALOG} \
        -name="ubuntu-ssh-host" \
        -description="Ubuntu v26 SSH Container" \
        -address=${SSH_IP} \
        -format=json | jq -r '.item.id')
    echo -e "${GREEN}✓ Host Created: ${HOST} (${SSH_IP})${NC}"
else
    echo -e "${YELLOW}✓ Host Found: ${HOST}${NC}"
    # Update address in case IP changed
    boundary hosts update static -id=${HOST} -address=${SSH_IP} > /dev/null
    echo -e "${GREEN}✓ Host address updated to: ${SSH_IP}${NC}"
fi
echo ""

# Step 4: Get or create host set
echo -e "${BLUE}==> Step 4: Getting or creating host set${NC}"
HOST_SET=$(boundary host-sets list -host-catalog-id=${HOST_CATALOG} -format=json | jq -r '.items[] | select(.name=="ubuntu-ssh-set") | .id' | head -1)

if [ -z "$HOST_SET" ]; then
    HOST_SET=$(boundary host-sets create static \
        -host-catalog-id=${HOST_CATALOG} \
        -name="ubuntu-ssh-set" \
        -description="Ubuntu SSH host set" \
        -format=json | jq -r '.item.id')
    echo -e "${GREEN}✓ Host Set Created: ${HOST_SET}${NC}"
else
    echo -e "${YELLOW}✓ Host Set Found: ${HOST_SET}${NC}"
fi

# Add host to host set (idempotent)
boundary host-sets add-hosts \
    -id=${HOST_SET} \
    -host=${HOST} > /dev/null 2>&1 || true

echo -e "${GREEN}✓ Host added to set${NC}"
echo ""

# Step 5: Create Vault SSH certificate library
echo -e "${BLUE}==> Step 5: Getting or creating Vault SSH certificate library${NC}"
CRED_LIBRARY=$(boundary credential-libraries list -credential-store-id=${VAULT_CRED_STORE} -format=json | jq -r '.items[] | select(.name=="ssh-cert-library") | .id' | head -1)

if [ -z "$CRED_LIBRARY" ]; then
    CRED_LIBRARY=$(boundary credential-libraries create vault-ssh-certificate \
        -credential-store-id=${VAULT_CRED_STORE} \
        -vault-path="ssh/sign/boundary-ssh" \
        -username="${SSH_USER}" \
        -name="ssh-cert-library" \
        -description="Vault SSH certificate library for Ubuntu" \
        -format=json | jq -r '.item.id')
    echo -e "${GREEN}✓ Credential Library Created: ${CRED_LIBRARY}${NC}"
else
    echo -e "${YELLOW}✓ Credential Library Found: ${CRED_LIBRARY}${NC}"
fi
echo ""

# Step 6: Get or create SSH target
echo -e "${BLUE}==> Step 6: Getting or creating SSH target${NC}"
TARGET=$(boundary targets list -scope-id=${PROJECT_SCOPE} -format=json | jq -r '.items[] | select(.name=="'${TARGET_NAME}'") | .id' | head -1)

if [ -z "$TARGET" ]; then
    TARGET=$(boundary targets create ssh \
        -scope-id=${PROJECT_SCOPE} \
        -name="${TARGET_NAME}" \
        -description="SSH access to Ubuntu v26 container with Vault credentials" \
        -default-port=${SSH_PORT} \
        -session-connection-limit=-1 \
        -format=json | jq -r '.item.id')
    echo -e "${GREEN}✓ Target Created: ${TARGET}${NC}"
else
    echo -e "${YELLOW}✓ Target Found: ${TARGET}${NC}"
fi
echo ""

# Step 7: Add host set to target
echo -e "${BLUE}==> Step 7: Adding host set to target${NC}"
boundary targets add-host-sources \
    -id=${TARGET} \
    -host-source=${HOST_SET} > /dev/null 2>&1 || true

echo -e "${GREEN}✓ Host set added to target${NC}"
echo ""

# Step 8: Add credential library to target
echo -e "${BLUE}==> Step 8: Adding Vault credential library to target${NC}"
boundary targets add-credential-sources \
    -id=${TARGET} \
    -injected-application-credential-source=${CRED_LIBRARY} > /dev/null 2>&1 || true

echo -e "${GREEN}✓ Vault SSH certificate library added to target${NC}"
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}  Boundary Target Setup Complete! ✓${NC}"
echo "=========================================="
echo ""
echo "Target Details:"
echo "  • Name: ${TARGET_NAME}"
echo "  • Target ID: ${TARGET}"
echo "  • Host: ${SSH_IP}:${SSH_PORT}"
echo "  • User: ${SSH_USER}"
echo "  • Credentials: Vault SSH Certificates (30 min TTL)"
echo ""
echo "Connect to the target:"
echo "  boundary connect ssh -target-id=${TARGET}"
echo ""
echo "Or use the Boundary UI:"
echo "  http://localhost:9200"
echo ""
echo "The connection will automatically:"
echo "  1. Request a signed SSH certificate from Vault"
echo "  2. Inject the certificate for authentication"
echo "  3. Connect you to the Ubuntu container as ${SSH_USER}"
echo ""

# Made with Bob