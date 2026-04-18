#!/bin/bash
set -e

# Configuration
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='hvs.REDACTED_TOKEN'
SSH_CONTAINER="zero_trust_boundary_ssh"
SSH_USER="danielle"
INITIAL_PASSWORD="YnkXV/6g1+Bd7fKKjfM07g=="

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "=========================================="
echo "  Vault OS Secrets Engine - Setup"
echo "=========================================="
echo ""

# Step 1: Get SSH container IP
echo -e "${BLUE}==> Step 1: Getting SSH container IP address${NC}"
SSH_IP=$(podman inspect ${SSH_CONTAINER} --format '{{range $net, $conf := .NetworkSettings.Networks}}{{if eq $net "zero_trust_net-data"}}{{$conf.IPAddress}}{{end}}{{end}}')

if [ -z "$SSH_IP" ]; then
    echo -e "${RED}✗ Failed to get IP address for ${SSH_CONTAINER}${NC}"
    echo "  Make sure the container is running and on the net-data network"
    exit 1
fi

echo -e "${GREEN}✓ SSH Container IP: ${SSH_IP}${NC}"
echo ""

# Step 2: Reset password in container
echo -e "${BLUE}==> Step 2: Resetting password in SSH container${NC}"
podman exec ${SSH_CONTAINER} bash -c "echo '${SSH_USER}:${INITIAL_PASSWORD}' | chpasswd"
echo -e "${GREEN}✓ Password reset to initial value${NC}"
echo ""

# Step 3: Check if OS secrets engine is enabled
echo -e "${BLUE}==> Step 3: Checking OS Secrets Engine${NC}"
if vault secrets list | grep -q "^os/"; then
    echo -e "${YELLOW}OS secrets engine already enabled, reconfiguring...${NC}"
    vault secrets disable os
fi

vault secrets enable -path=os -plugin-version="0.1.0+ent" vault-plugin-secrets-os
echo -e "${GREEN}✓ OS secrets engine enabled${NC}"
echo ""

# Step 4: Configure OS secrets engine
echo -e "${BLUE}==> Step 4: Configuring OS secrets engine${NC}"
vault write os/config ssh_host_key_trust_on_first_use=true
echo -e "${GREEN}✓ SSH host key trust configured${NC}"
echo ""

# Step 5: Create password policy
echo -e "${BLUE}==> Step 5: Creating password policy${NC}"
cat > /tmp/password_policy.hcl <<-'EOF'
length = 20
rule "charset" {
   charset = "abcdefghijklmnopqrstuvwxyz"
   min-chars = 1
}
EOF

vault write sys/policies/password/rhel-policy policy=@/tmp/password_policy.hcl
echo -e "${GREEN}✓ Password policy 'rhel-policy' created${NC}"
echo ""

# Step 6: Configure host
echo -e "${BLUE}==> Step 6: Configuring SSH host${NC}"
vault write os/hosts/ssh-host1 \
    address=${SSH_IP} \
    port=22

echo -e "${GREEN}✓ Host 'ssh-host1' configured${NC}"
echo "  Address: ${SSH_IP}:22"
echo ""

# Step 7: Configure managed account
echo -e "${BLUE}==> Step 7: Configuring managed account${NC}"
vault write os/hosts/ssh-host1/accounts/${SSH_USER} \
    rotation_period="1m" \
    username="${SSH_USER}" \
    password_policy="rhel-policy" \
    password="${INITIAL_PASSWORD}"

echo -e "${GREEN}✓ Account '${SSH_USER}' configured${NC}"
echo "  Rotation Period: 1 minute"
echo "  Password Policy: rhel-policy"
echo ""

# Step 8: Verify setup
echo -e "${BLUE}==> Step 8: Verifying setup${NC}"
CREDS=$(vault read -format=json os/hosts/ssh-host1/accounts/${SSH_USER}/creds)
PASSWORD=$(echo "$CREDS" | jq -r '.data.password')
VERSION=$(echo "$CREDS" | jq -r '.data.version')

echo -e "${GREEN}✓ Successfully retrieved credentials${NC}"
echo "  Username: ${SSH_USER}"
echo "  Password: ${PASSWORD}"
echo "  Version: ${VERSION}"
echo ""

# Step 9: Test password on SSH host
echo -e "${BLUE}==> Step 9: Testing password on SSH host${NC}"
TEST_RESULT=$(podman exec ${SSH_CONTAINER} su - ${SSH_USER} -c "echo '${PASSWORD}' | sudo -S whoami 2>/dev/null" || echo "FAILED")

if [ "$TEST_RESULT" = "root" ]; then
    echo -e "${GREEN}✓ Password authentication successful!${NC}"
else
    echo -e "${RED}✗ Password authentication failed${NC}"
    exit 1
fi
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}  Setup Complete! ✓${NC}"
echo "=========================================="
echo ""
echo "Configuration Summary:"
echo "  • SSH Host: ssh-host1 (${SSH_IP}:22)"
echo "  • Account: ${SSH_USER}"
echo "  • Rotation Period: 1 minute"
echo "  • Password Policy: rhel-policy (20 chars, lowercase)"
echo "  • Current Version: ${VERSION}"
echo ""
echo "Next Steps:"
echo "  1. Run ./scripts/verify_linux_rotation.sh to test rotation"
echo "  2. Wait 1 minute for automatic rotation"
echo "  3. Read credentials: vault read os/hosts/ssh-host1/accounts/${SSH_USER}/creds"
echo ""
echo "Note: The IP address (${SSH_IP}) is automatically detected from the container."
echo "If the container restarts, run this script again to update the configuration."

# Made with Bob
