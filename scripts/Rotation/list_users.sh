#!/bin/bash
set -e

# List Users in Ubuntu Container
# Shows users configured for Vault OS Secrets Engine

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Configuration
SSH_CONTAINER="zero_trust_boundary_ssh"

echo "=========================================="
echo "  Users in Ubuntu Container"
echo "=========================================="
echo ""

# Check if container is running
if ! podman ps | grep -q ${SSH_CONTAINER}; then
    echo -e "${RED}✗ Container ${SSH_CONTAINER} is not running${NC}"
    exit 1
fi

echo -e "${BLUE}Container: ${SSH_CONTAINER}${NC}"
echo ""

# Get all users with UID >= 1000 (regular users, not system users)
echo -e "${BLUE}==> Regular Users (UID >= 1000):${NC}"
echo ""

USERS=$(podman exec ${SSH_CONTAINER} bash -c "
getent passwd | awk -F: '\$3 >= 1000 && \$3 < 65534 {print \$1\":\"\$3\":\"\$6\":\"\$7}'
")

if [ -z "$USERS" ]; then
    echo -e "${YELLOW}No regular users found${NC}"
else
    printf "%-15s %-8s %-25s %-20s %s\n" "USERNAME" "UID" "HOME" "SHELL" "SUDO"
    echo "--------------------------------------------------------------------------------"
    
    echo "$USERS" | while IFS=: read -r username uid home shell; do
        # Check if user has sudo permissions
        SUDO_CHECK=$(podman exec ${SSH_CONTAINER} bash -c "
        if [ -f /etc/sudoers.d/${username} ]; then
            echo 'yes'
        elif groups ${username} 2>/dev/null | grep -q sudo; then
            echo 'yes'
        else
            echo 'no'
        fi
        " 2>/dev/null)
        
        SUDO_MARKER="no"
        SUDO_COLOR="${NC}"
        if [ "$SUDO_CHECK" = "yes" ]; then
            SUDO_MARKER="yes"
            SUDO_COLOR="${GREEN}"
        fi
        
        printf "%-15s %-8s %-25s %-20s ${SUDO_COLOR}%s${NC}\n" "$username" "$uid" "$home" "$shell" "$SUDO_MARKER"
    done
fi

echo ""
echo -e "${BLUE}==> System Users (UID < 1000):${NC}"
SYSTEM_COUNT=$(podman exec ${SSH_CONTAINER} bash -c "getent passwd | awk -F: '\$3 < 1000' | wc -l")
echo "  ${SYSTEM_COUNT} system users (use 'getent passwd' in container to see all)"
echo ""

# Check for users configured in Vault
echo -e "${BLUE}==> Vault OS Secrets Engine Status:${NC}"
if [ -n "${VAULT_TOKEN}" ] && [ "${VAULT_TOKEN}" != "hvs.REPLACE_WITH_YOUR_TOKEN" ]; then
    export VAULT_ADDR='http://127.0.0.1:8200'
    
    if vault status > /dev/null 2>&1; then
        echo ""
        echo "Checking for users configured in Vault..."
        
        # Try to list accounts
        VAULT_ACCOUNTS=$(timeout 5 vault list -format=json os/hosts/ssh-host1/accounts 2>/dev/null | jq -r '.[]' 2>/dev/null || echo "")
        
        if [ -n "$VAULT_ACCOUNTS" ]; then
            echo ""
            printf "%-15s %-10s %-20s %-15s\n" "USERNAME" "VERSION" "LAST ROTATION" "ROTATION PERIOD"
            echo "--------------------------------------------------------------------------------"
            
            echo "$VAULT_ACCOUNTS" | while read -r account; do
                # Get account info
                ACCOUNT_DATA=$(timeout 5 vault read -format=json os/hosts/ssh-host1/accounts/${account} 2>/dev/null)
                CREDS_DATA=$(timeout 5 vault read -format=json os/hosts/ssh-host1/accounts/${account}/creds 2>/dev/null)
                
                if [ $? -eq 0 ]; then
                    VERSION=$(echo "$CREDS_DATA" | jq -r '.data.version')
                    LAST_ROT=$(echo "$CREDS_DATA" | jq -r '.data.created_time' | cut -d'T' -f1,2 | tr 'T' ' ')
                    ROT_PERIOD=$(echo "$ACCOUNT_DATA" | jq -r '.data.rotation_period')
                    
                    printf "%-15s %-10s %-20s %-15s\n" "$account" "$VERSION" "$LAST_ROT" "${ROT_PERIOD}s"
                fi
            done
            
            echo ""
            echo -e "${GREEN}✓ ${VAULT_ACCOUNTS} account(s) configured in Vault${NC}"
        else
            echo -e "${YELLOW}  No accounts configured in Vault OS Secrets Engine${NC}"
            echo ""
            echo "  To add a user to Vault:"
            echo "    vault write os/hosts/ssh-host1/accounts/<username> \\"
            echo "      username=<username> \\"
            echo "      password=<initial-password> \\"
            echo "      rotation_period=60"
        fi
    else
        echo -e "${YELLOW}  Vault not accessible${NC}"
        echo "  Set VAULT_TOKEN to check Vault configuration"
    fi
else
    echo -e "${YELLOW}  Set VAULT_TOKEN to check Vault configuration${NC}"
    echo ""
    echo "  Example:"
    echo "    export VAULT_TOKEN=<your-token>"
    echo "    $0"
fi

echo ""
echo "=========================================="
echo -e "${GREEN}  User List Complete${NC}"
echo "=========================================="
echo ""

# Made with Bob