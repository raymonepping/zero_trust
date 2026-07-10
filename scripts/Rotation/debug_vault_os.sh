#!/bin/bash

# Debug Vault OS Secrets Engine
# This script helps diagnose why user accounts aren't being saved

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=========================================="
echo -e "  Vault OS Secrets Engine Debug"
echo -e "==========================================${NC}\n"

# Check Vault connection
echo -e "${BLUE}1. Checking Vault connection...${NC}"
export VAULT_ADDR='http://127.0.0.1:8200'
if vault status > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Vault is accessible${NC}"
    vault status | grep -E "(Sealed|Version|Cluster)"
else
    echo -e "${RED}✗ Cannot connect to Vault${NC}"
    exit 1
fi
echo ""

# Check if OS Secrets Engine is enabled
echo -e "${BLUE}2. Checking OS Secrets Engine mount...${NC}"
if vault secrets list | grep -q "^os/"; then
    echo -e "${GREEN}✓ OS Secrets Engine is mounted at 'os/'${NC}"
else
    echo -e "${RED}✗ OS Secrets Engine is NOT mounted${NC}"
    echo "Run: vault secrets enable -path=os vault-plugin-secrets-os"
    exit 1
fi
echo ""

# Check SSH host configuration
echo -e "${BLUE}3. Checking SSH host configuration...${NC}"
if vault list os/hosts 2>/dev/null | grep -q "ssh-host1"; then
    echo -e "${GREEN}✓ SSH host 'ssh-host1' exists${NC}"
    echo ""
    echo "Host details:"
    vault read os/hosts/ssh-host1
else
    echo -e "${RED}✗ SSH host 'ssh-host1' not found${NC}"
    echo "Available hosts:"
    vault list os/hosts 2>/dev/null || echo "  (none)"
fi
echo ""

# Try to read the host configuration with -format=json for debugging
echo -e "${BLUE}4. Reading host configuration (JSON)...${NC}"
HOST_CONFIG=$(vault read -format=json os/hosts/ssh-host1 2>&1)
if [ $? -eq 0 ]; then
    echo "$HOST_CONFIG" | jq '.'
else
    echo -e "${RED}✗ Failed to read host config${NC}"
    echo "$HOST_CONFIG"
fi
echo ""

# Check if we can list accounts
echo -e "${BLUE}5. Checking for configured accounts...${NC}"
ACCOUNTS=$(vault list -format=json os/hosts/ssh-host1/accounts 2>&1)
if [ $? -eq 0 ]; then
    ACCOUNT_COUNT=$(echo "$ACCOUNTS" | jq -r '. | length')
    if [ "$ACCOUNT_COUNT" -gt 0 ]; then
        echo -e "${GREEN}✓ Found ${ACCOUNT_COUNT} account(s)${NC}"
        echo "$ACCOUNTS" | jq -r '.[]' | while read -r account; do
            echo "  - ${account}"
        done
    else
        echo -e "${YELLOW}⚠ No accounts configured${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Cannot list accounts (this is normal if none exist)${NC}"
    echo "Error: $ACCOUNTS"
fi
echo ""

# Test creating a test account
echo -e "${BLUE}6. Testing account creation...${NC}"
TEST_USER="test_debug_user"
TEST_PASS="TestPass123!"

# Get container IP
CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' zero_trust_boundary_ssh 2>/dev/null)
echo "Container IP: ${CONTAINER_IP}"
echo ""

# First, ensure the test user exists in the container
echo "Creating test user in container..."
docker exec zero_trust_boundary_ssh bash -c "
    if ! id ${TEST_USER} > /dev/null 2>&1; then
        useradd -m -s /bin/bash ${TEST_USER}
        echo '${TEST_USER}:${TEST_PASS}' | chpasswd
        usermod -aG sudo ${TEST_USER}
        echo '${TEST_USER} ALL=NOPASSWD:/usr/sbin/chpasswd' > /etc/sudoers.d/${TEST_USER}
        chmod 0440 /etc/sudoers.d/${TEST_USER}
        echo 'User created'
    else
        echo 'User already exists'
    fi
"
echo ""

# Update host address
echo "Updating SSH host address..."
vault write os/hosts/ssh-host1 address="${CONTAINER_IP}" port=22
echo ""

# Try to create the account in Vault
echo "Attempting to create account in Vault..."
echo "Command: vault write os/hosts/ssh-host1/accounts/${TEST_USER} username=${TEST_USER} password=${TEST_PASS} rotation_period=60"
echo ""

OUTPUT=$(vault write os/hosts/ssh-host1/accounts/${TEST_USER} \
    username=${TEST_USER} \
    password=${TEST_PASS} \
    rotation_period=60 2>&1)

EXIT_CODE=$?
echo "Exit code: ${EXIT_CODE}"
echo "Output:"
echo "$OUTPUT"
echo ""

if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✓ Account creation successful!${NC}"
    echo ""
    echo "Verifying account..."
    vault read os/hosts/ssh-host1/accounts/${TEST_USER}
    echo ""
    echo "Reading credentials..."
    vault read os/hosts/ssh-host1/accounts/${TEST_USER}/creds
else
    echo -e "${RED}✗ Account creation failed${NC}"
    echo ""
    echo "Checking Vault logs for errors..."
    docker logs zero_trust_vault --tail 50 2>&1 | grep -i "error\|fail\|ssh-host1" | tail -20
fi

echo ""
echo -e "${BLUE}=========================================="
echo -e "  Debug Complete"
echo -e "==========================================${NC}"

# Made with Bob
