#!/bin/bash
set -e

# Restore Vault OS Secrets Engine Configuration
# This script checks if the OS Secrets Engine is properly configured
# and restores it if needed after a Vault restart

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=========================================="
echo -e "  Vault OS Secrets Engine Restore"
echo -e "==========================================${NC}\n"

# Check if Vault is accessible
if ! vault status > /dev/null 2>&1; then
    echo -e "${RED}✗ Vault is not accessible${NC}"
    echo "  Make sure VAULT_ADDR and VAULT_TOKEN are set"
    exit 1
fi

echo -e "${GREEN}✓ Vault is accessible${NC}\n"

# Check if plugin is registered
echo -e "${BLUE}Checking plugin registration...${NC}"
PLUGIN_REGISTERED=$(vault plugin list secret 2>/dev/null | grep -c "vault-plugin-secrets-os" || echo "0")

if [ "$PLUGIN_REGISTERED" -eq 0 ]; then
    echo -e "${YELLOW}⚠ OS Secrets plugin not registered${NC}"
    echo -e "${BLUE}Registering plugin...${NC}"
    
    # Calculate SHA256 of the plugin
    PLUGIN_SHA=$(sha256sum /vault/plugins/vault-plugin-secrets-os | cut -d' ' -f1)
    
    # Register the plugin
    vault plugin register \
        -sha256="${PLUGIN_SHA}" \
        -command="vault-plugin-secrets-os" \
        secret vault-plugin-secrets-os
    
    echo -e "${GREEN}✓ Plugin registered${NC}\n"
else
    echo -e "${GREEN}✓ Plugin already registered${NC}\n"
fi

# Check if secrets engine is enabled
echo -e "${BLUE}Checking if OS Secrets Engine is enabled...${NC}"
ENGINE_ENABLED=$(vault secrets list -format=json 2>/dev/null | jq -r 'keys[]' | grep -c "^os/$" || echo "0")

if [ "$ENGINE_ENABLED" -eq 0 ]; then
    echo -e "${YELLOW}⚠ OS Secrets Engine not enabled${NC}"
    echo -e "${BLUE}Enabling OS Secrets Engine at path 'os/'...${NC}"
    
    vault secrets enable -path=os vault-plugin-secrets-os
    
    echo -e "${GREEN}✓ OS Secrets Engine enabled${NC}\n"
else
    echo -e "${GREEN}✓ OS Secrets Engine already enabled${NC}\n"
fi

# Check if password policy exists
echo -e "${BLUE}Checking password policy...${NC}"
POLICY_EXISTS=$(vault read sys/policies/password/rhel-policy > /dev/null 2>&1 && echo "1" || echo "0")

if [ "$POLICY_EXISTS" -eq 0 ]; then
    echo -e "${YELLOW}⚠ Password policy 'rhel-policy' not found${NC}"
    echo -e "${BLUE}Creating password policy...${NC}"
    
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
    
    echo -e "${GREEN}✓ Password policy created${NC}\n"
else
    echo -e "${GREEN}✓ Password policy exists${NC}\n"
fi

# Check if SSH host is configured
echo -e "${BLUE}Checking SSH host configuration...${NC}"
SSH_HOST_EXISTS=$(vault list os/hosts 2>/dev/null | grep -c "ssh-host1" || echo "0")

if [ "$SSH_HOST_EXISTS" -eq 0 ]; then
    echo -e "${YELLOW}⚠ SSH host 'ssh-host1' not configured${NC}"
    echo -e "${BLUE}Configuring SSH host...${NC}"
    
    # Get container IP
    CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' zero_trust_boundary_ssh 2>/dev/null || echo "")
    
    if [ -z "$CONTAINER_IP" ]; then
        echo -e "${RED}✗ Could not detect container IP${NC}"
        echo "  Please run: docker inspect zero_trust_boundary_ssh"
        exit 1
    fi
    
    echo -e "  Container IP: ${CONTAINER_IP}"
    
    # Configure SSH host
    vault write os/hosts/ssh-host1 \
        address="${CONTAINER_IP}" \
        port=22
    
    echo -e "${GREEN}✓ SSH host configured${NC}\n"
else
    echo -e "${GREEN}✓ SSH host already configured${NC}\n"
    
    # Update IP in case it changed
    CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' zero_trust_boundary_ssh 2>/dev/null || echo "")
    if [ -n "$CONTAINER_IP" ]; then
        echo -e "${BLUE}Updating SSH host IP to: ${CONTAINER_IP}${NC}"
        vault write os/hosts/ssh-host1 \
            address="${CONTAINER_IP}" \
            port=22
        echo -e "${GREEN}✓ SSH host IP updated${NC}\n"
    fi
fi

# List configured accounts
echo -e "${BLUE}Checking configured accounts...${NC}"
ACCOUNTS=$(vault list -format=json os/hosts/ssh-host1/accounts 2>/dev/null | jq -r '.[]' 2>/dev/null || echo "")

if [ -z "$ACCOUNTS" ]; then
    echo -e "${YELLOW}⚠ No accounts configured in Vault${NC}"
    echo -e "\n${BLUE}To add users, run:${NC}"
    echo -e "  ./add_user.sh --username <username>"
else
    echo -e "${GREEN}✓ Found configured accounts:${NC}"
    echo "$ACCOUNTS" | while read -r account; do
        echo -e "  - ${account}"
    done
fi

echo -e "\n${BLUE}=========================================="
echo -e "  Restore Complete"
echo -e "==========================================${NC}\n"

echo -e "${GREEN}Summary:${NC}"
echo -e "  • Plugin: Registered"
echo -e "  • Engine: Enabled at 'os/'"
echo -e "  • Policy: rhel-policy configured"
echo -e "  • SSH Host: ssh-host1 configured"

if [ -n "$ACCOUNTS" ]; then
    ACCOUNT_COUNT=$(echo "$ACCOUNTS" | wc -l | tr -d ' ')
    echo -e "  • Accounts: ${ACCOUNT_COUNT} configured"
else
    echo -e "  • Accounts: None (use add_user.sh to add)"
fi

echo ""

# Made with Bob
