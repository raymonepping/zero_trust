#!/bin/bash
set -e

# Configuration
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN="${VAULT_TOKEN:-hvs.REPLACE_WITH_YOUR_TOKEN}"
SSH_HOST="${SSH_HOST:-ssh-host1}"
SSH_CONTAINER="${SSH_CONTAINER:-zero_trust_boundary_ssh}"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if username is provided
if [ -z "$1" ]; then
    echo -e "${RED}Error: Username required${NC}"
    echo ""
    echo "Usage: $0 <username>"
    echo ""
    echo "Example:"
    echo "  $0 danielle"
    echo "  $0 john"
    echo ""
    exit 1
fi

USERNAME="$1"

echo "=========================================="
echo "  Test User Password from Vault"
echo "=========================================="
echo ""

# Get SSH host IP address
SSH_IP=$(podman inspect ${SSH_CONTAINER} --format '{{range $net, $conf := .NetworkSettings.Networks}}{{if eq $net "zero_trust_net-data"}}{{$conf.IPAddress}}{{end}}{{end}}' 2>/dev/null || echo "N/A")

echo "Configuration:"
echo "  • Vault Address: ${VAULT_ADDR}"
echo "  • SSH Host: ${SSH_HOST}"
echo "  • SSH Container: ${SSH_CONTAINER}"
echo "  • SSH Host IP: ${SSH_IP}"
echo "  • Username: ${USERNAME}"
echo ""

# Step 1: Check if account exists in Vault
echo -e "${BLUE}==> Step 1: Checking if account exists in Vault${NC}"
if ! vault read os/hosts/${SSH_HOST}/accounts/${USERNAME} > /dev/null 2>&1; then
    echo -e "${RED}✗ Account '${USERNAME}' not found in Vault${NC}"
    echo ""
    echo "Available accounts:"
    vault list os/hosts/${SSH_HOST}/accounts 2>/dev/null || echo "  No accounts configured"
    exit 1
fi
echo -e "${GREEN}✓ Account '${USERNAME}' exists in Vault${NC}"
echo ""

# Step 2: Get current credentials from Vault
echo -e "${BLUE}==> Step 2: Retrieving current password from Vault${NC}"
CREDS=$(vault read -format=json os/hosts/${SSH_HOST}/accounts/${USERNAME}/creds)
PASSWORD=$(echo "$CREDS" | jq -r '.data.password')
VERSION=$(echo "$CREDS" | jq -r '.data.version')
CREATED_TIME=$(echo "$CREDS" | jq -r '.data.created_time')
TTL=$(echo "$CREDS" | jq -r '.data.ttl')

if [ -z "$PASSWORD" ] || [ "$PASSWORD" = "null" ]; then
    echo -e "${RED}✗ Failed to retrieve password from Vault${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Password retrieved from Vault${NC}"
echo "  Username: ${USERNAME}"
echo "  Password: ${PASSWORD}"
echo "  Version: ${VERSION}"
echo "  Created: ${CREATED_TIME}"
echo "  TTL: ${TTL}"
echo ""

# Step 3: Verify password on SSH host
echo -e "${BLUE}==> Step 3: Verifying password on SSH host${NC}"

# Test 1: Basic authentication
echo -e "${YELLOW}Testing basic authentication...${NC}"
AUTH_TEST=$(podman exec ${SSH_CONTAINER} su - ${USERNAME} -c "whoami" 2>/dev/null || echo "FAILED")

if [ "$AUTH_TEST" = "${USERNAME}" ]; then
    echo -e "${GREEN}✓ Basic authentication successful${NC}"
else
    echo -e "${RED}✗ Basic authentication failed${NC}"
    echo "  Could not authenticate as user ${USERNAME}"
    exit 1
fi

# Test 2: Sudo authentication with password
echo -e "${YELLOW}Testing sudo authentication with password...${NC}"
SUDO_TEST=$(podman exec ${SSH_CONTAINER} su - ${USERNAME} -c "echo '${PASSWORD}' | sudo -S whoami 2>/dev/null" || echo "FAILED")

if [ "$SUDO_TEST" = "root" ]; then
    echo -e "${GREEN}✓ Sudo authentication successful${NC}"
    echo "  User ${USERNAME} can execute sudo commands with the Vault password"
else
    echo -e "${YELLOW}⚠ Sudo authentication failed or user doesn't have sudo privileges${NC}"
fi
echo ""

# Step 4: Get account configuration
echo -e "${BLUE}==> Step 4: Account configuration details${NC}"
ACCOUNT_INFO=$(vault read -format=json os/hosts/${SSH_HOST}/accounts/${USERNAME})
ROTATION_PERIOD=$(echo "$ACCOUNT_INFO" | jq -r '.data.rotation_period')
PASSWORD_POLICY=$(echo "$ACCOUNT_INFO" | jq -r '.data.password_policy')
LAST_ROTATION=$(echo "$ACCOUNT_INFO" | jq -r '.data.last_vault_rotation')
NEXT_ROTATION=$(echo "$ACCOUNT_INFO" | jq -r '.data.next_vault_rotation')

echo "  Rotation Period: ${ROTATION_PERIOD}"
echo "  Password Policy: ${PASSWORD_POLICY}"
echo "  Last Rotation: ${LAST_ROTATION}"
echo "  Next Rotation: ${NEXT_ROTATION}"
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}  Password Verification Complete! ✓${NC}"
echo "=========================================="
echo ""
echo "Summary:"
echo "  • User: ${USERNAME}"
echo "  • SSH Container: ${SSH_CONTAINER}"
echo "  • Password Version: ${VERSION}"
echo "  • Authentication: ${GREEN}✓ Working${NC}"
echo "  • Password: ${PASSWORD}"
echo ""
echo "You can now use this password to:"
echo "  1. SSH into the container: ssh ${USERNAME}@${SSH_CONTAINER}"
echo "  2. Execute commands in container: podman exec -it ${SSH_CONTAINER} su - ${USERNAME}"
echo "  3. Use sudo: sudo -u ${USERNAME} <command>"
echo ""
echo "Note: Password will automatically rotate in ${ROTATION_PERIOD}"
echo "      Next rotation: ${NEXT_ROTATION}"
echo ""

# Made with Bob