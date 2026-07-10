#!/bin/bash
set -e

# Fix Vault SSH Role - Add Certificate Extensions for PTY
# SSH certificates need specific extensions to allow PTY allocation

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "=========================================="
echo "  Fix Vault SSH Role for PTY Support"
echo "=========================================="
echo ""

# Configuration
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN="${VAULT_TOKEN:-hvs.REPLACE_WITH_YOUR_TOKEN}"

# Step 1: Check Vault connection
echo -e "${BLUE}==> Step 1: Checking Vault connection${NC}"
if ! vault status > /dev/null 2>&1; then
    echo -e "${RED}✗ Cannot connect to Vault at ${VAULT_ADDR}${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Connected to Vault${NC}"
echo ""

# Step 2: Read current SSH role configuration
echo -e "${BLUE}==> Step 2: Reading current SSH role configuration${NC}"
if vault read ssh/roles/boundary-ssh > /dev/null 2>&1; then
    echo -e "${GREEN}✓ SSH role 'boundary-ssh' exists${NC}"
    vault read ssh/roles/boundary-ssh
else
    echo -e "${RED}✗ SSH role 'boundary-ssh' not found${NC}"
    echo -e "${YELLOW}Run setup_ssh_ca.sh first to create the role${NC}"
    exit 1
fi
echo ""

# Step 3: Update SSH role with certificate extensions
echo -e "${BLUE}==> Step 3: Updating SSH role with certificate extensions${NC}"
echo -e "${YELLOW}Adding extensions for PTY, X11, agent forwarding, and port forwarding${NC}"

# Create payload file
cat > /tmp/ssh_role_payload.json <<'EOF'
{
  "key_type": "ca",
  "ttl": "30m",
  "allow_user_certificates": true,
  "allowed_users": "danielle,ubuntu,root",
  "default_extensions": {
    "permit-pty": "",
    "permit-X11-forwarding": "",
    "permit-agent-forwarding": "",
    "permit-port-forwarding": ""
  }
}
EOF

# Use curl to write the role with proper JSON
curl -X POST \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d @/tmp/ssh_role_payload.json \
    ${VAULT_ADDR}/v1/ssh/roles/boundary-ssh

# Cleanup
rm -f /tmp/ssh_role_payload.json

echo -e "${GREEN}✓ SSH role updated with certificate extensions${NC}"
echo ""

# Step 4: Verify the updated configuration
echo -e "${BLUE}==> Step 4: Verifying updated configuration${NC}"
vault read ssh/roles/boundary-ssh
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}  SSH Role Update Complete! ✓${NC}"
echo "=========================================="
echo ""
echo "The Vault SSH role now includes certificate extensions:"
echo "  • permit-pty: Allows PTY allocation (fixes your error!)"
echo "  • permit-X11-forwarding: Allows X11 forwarding"
echo "  • permit-agent-forwarding: Allows SSH agent forwarding"
echo "  • permit-port-forwarding: Allows port forwarding"
echo ""
echo "These extensions are automatically added to all signed certificates."
echo ""
echo "Test your Boundary SSH connection:"
echo "  boundary connect ssh -target-id=<your-target-id>"
echo ""
echo "The PTY allocation error should now be resolved!"
echo ""

# Made with Bob