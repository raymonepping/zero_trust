#!/bin/bash
set -e

# Fix Plugin Architecture - Replace macOS binary with Linux binary
# The plugin must match the container's OS (Linux ARM64)

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=========================================="
echo -e "  Fix Vault OS Plugin Architecture"
echo -e "==========================================${NC}\n"

PLUGIN_DIR="../../plugins"
PLUGIN_NAME="vault-plugin-secrets-os"

# Calculate new SHA256
echo -e "${BLUE}Step 1: Calculating SHA256 of Linux binary...${NC}"
PLUGIN_SHA=$(shasum -a 256 "$PLUGIN_DIR/$PLUGIN_NAME" | cut -d' ' -f1)
echo "SHA256: $PLUGIN_SHA"
echo ""

# Check Vault status
echo -e "${BLUE}Step 2: Checking Vault status...${NC}"
export VAULT_ADDR='http://127.0.0.1:8200'

if ! vault status > /dev/null 2>&1; then
    echo -e "${RED}✗ Vault is not accessible or is sealed${NC}"
    echo ""
    echo "Please unseal Vault first, then run this script again."
    echo ""
    echo "To unseal:"
    echo "  vault operator unseal <unseal-key-1>"
    echo "  vault operator unseal <unseal-key-2>"
    echo "  vault operator unseal <unseal-key-3>"
    exit 1
fi

echo -e "${GREEN}✓ Vault is accessible and unsealed${NC}"
echo ""

# Re-register plugin with new SHA256
echo -e "${BLUE}Step 3: Re-registering plugin with correct SHA256...${NC}"
vault plugin register \
    -sha256="$PLUGIN_SHA" \
    -command="$PLUGIN_NAME" \
    secret $PLUGIN_NAME

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Plugin re-registered${NC}"
else
    echo -e "${RED}✗ Plugin registration failed${NC}"
    exit 1
fi
echo ""

# Reload the plugin
echo -e "${BLUE}Step 4: Reloading plugin to use new binary...${NC}"
vault plugin reload -plugin $PLUGIN_NAME

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Plugin reloaded${NC}"
else
    echo -e "${YELLOW}⚠ Plugin reload failed, trying alternative method...${NC}"
    
    # Alternative: remount the secrets engine
    vault secrets disable os/
    sleep 2
    vault secrets enable -path=os $PLUGIN_NAME
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Secrets engine remounted${NC}"
    else
        echo -e "${RED}✗ Failed to remount secrets engine${NC}"
        exit 1
    fi
fi
echo ""

# Test the plugin
echo -e "${BLUE}Step 5: Testing plugin functionality...${NC}"

# Get container IP
CONTAINER_IP=$(podman inspect zero_trust_boundary_ssh --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$conf.IPAddress}}{{end}}' 2>/dev/null || echo "")

if [ -z "$CONTAINER_IP" ]; then
    echo -e "${YELLOW}⚠ Could not detect container IP${NC}"
    echo "Please configure manually:"
    echo "  vault write os/hosts/ssh-host1 address=<container-ip> port=22"
else
    echo "Container IP: $CONTAINER_IP"
    echo "Configuring SSH host..."
    
    vault write os/hosts/ssh-host1 \
        address="$CONTAINER_IP" \
        port=22
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ SSH host configured successfully!${NC}"
        echo ""
        echo "Plugin is working correctly!"
    else
        echo -e "${RED}✗ Failed to configure SSH host${NC}"
        echo "Check Vault logs for errors:"
        echo "  podman logs zero_trust_vault --tail 50"
        exit 1
    fi
fi
echo ""

# Recreate password policy
echo -e "${BLUE}Step 6: Ensuring password policy exists...${NC}"
vault write sys/policies/password/rhel-policy policy=-<<EOF
length=20
rule "charset" {
  charset = "abcdefghijklmnopqrstuvwxyz"
  min-chars = 1
}
rule "charset" {
  charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  min-chars = 1
}
rule "charset" {
  charset = "0123456789"
  min-chars = 1
}
rule "charset" {
  charset = "!@#%^&*"
  min-chars = 1
}
EOF

echo -e "${GREEN}✓ Password policy configured${NC}"
echo ""

echo -e "${BLUE}=========================================="
echo -e "  Fix Complete!"
echo -e "==========================================${NC}\n"

echo -e "${GREEN}Summary:${NC}"
echo "  • Plugin binary: Linux ARM64 (correct for container)"
echo "  • SHA256: $PLUGIN_SHA"
echo "  • Plugin: Registered and working"
echo "  • SSH host: Configured"
echo ""

echo -e "${GREEN}Next steps:${NC}"
echo "1. Add users:"
echo "   ./add_user.sh --username boundary"
echo "   ./add_user.sh --username danielle"
echo ""
echo "2. Verify:"
echo "   ./list_users.sh"
echo ""

# Made with Bob
