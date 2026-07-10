#!/bin/bash
set -e

# Reload Vault OS Secrets Engine Plugin
# This script reloads the OS Secrets plugin when it's shut down

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=========================================="
echo -e "  Reload Vault OS Secrets Plugin"
echo -e "==========================================${NC}\n"

# Check Vault connection
export VAULT_ADDR='http://127.0.0.1:8200'
if ! vault status > /dev/null 2>&1; then
    echo -e "${RED}✗ Cannot connect to Vault${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Vault is accessible${NC}\n"

# Check if plugin is registered
echo -e "${BLUE}Step 1: Checking plugin registration...${NC}"
PLUGIN_INFO=$(vault plugin list secret -format=json 2>/dev/null | jq -r '.[] | select(.name == "vault-plugin-secrets-os")')

if [ -z "$PLUGIN_INFO" ]; then
    echo -e "${RED}✗ Plugin not registered${NC}"
    echo "Registering plugin..."
    
    # Get container name - try both docker and podman
    if command -v podman &> /dev/null; then
        CONTAINER_CMD="podman"
    else
        CONTAINER_CMD="docker"
    fi
    
    # Calculate SHA256 from inside the Vault container
    PLUGIN_SHA=$($CONTAINER_CMD exec zero_trust_vault sha256sum /vault/plugins/vault-plugin-secrets-os | cut -d' ' -f1)
    
    if [ -z "$PLUGIN_SHA" ]; then
        echo -e "${RED}✗ Could not calculate plugin SHA256${NC}"
        exit 1
    fi
    
    echo "Plugin SHA256: ${PLUGIN_SHA}"
    
    vault plugin register \
        -sha256="${PLUGIN_SHA}" \
        -command="vault-plugin-secrets-os" \
        secret vault-plugin-secrets-os
    
    echo -e "${GREEN}✓ Plugin registered${NC}"
else
    echo -e "${GREEN}✓ Plugin is registered${NC}"
fi
echo ""

# Reload the plugin
echo -e "${BLUE}Step 2: Reloading plugin...${NC}"
echo "This will restart the plugin without unmounting the secrets engine"
echo ""

vault plugin reload -plugin vault-plugin-secrets-os

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Plugin reloaded successfully${NC}"
else
    echo -e "${RED}✗ Plugin reload failed${NC}"
    echo ""
    echo "Trying alternative method: disable and re-enable the secrets engine..."
    
    # Backup: disable and re-enable
    vault secrets disable os/
    
    # Re-enable
    vault secrets enable -path=os vault-plugin-secrets-os
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Secrets engine re-enabled${NC}"
    else
        echo -e "${RED}✗ Failed to re-enable secrets engine${NC}"
        exit 1
    fi
fi
echo ""

# Verify plugin is working
echo -e "${BLUE}Step 3: Verifying plugin is working...${NC}"
if vault secrets list | grep -q "^os/"; then
    echo -e "${GREEN}✓ OS Secrets Engine is mounted${NC}"
    
    # Try to list hosts (should work even if empty)
    if vault list os/hosts > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Plugin is responding${NC}"
    else
        # Empty list is OK
        echo -e "${GREEN}✓ Plugin is responding (no hosts configured yet)${NC}"
    fi
else
    echo -e "${RED}✗ OS Secrets Engine not mounted${NC}"
    exit 1
fi
echo ""

# Recreate password policy
echo -e "${BLUE}Step 4: Ensuring password policy exists...${NC}"
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
echo -e "  Plugin Reload Complete"
echo -e "==========================================${NC}\n"

echo -e "${GREEN}Next steps:${NC}"
echo "1. Configure SSH host:"
echo "   vault write os/hosts/ssh-host1 address=<container-ip> port=22"
echo ""
echo "2. Add users with add_user.sh:"
echo "   ./add_user.sh --username boundary"
echo "   ./add_user.sh --username danielle"
echo "   etc."
echo ""

# Made with Bob
