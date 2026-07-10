#!/bin/bash
set -e

# Configuration
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN="${VAULT_TOKEN:-hvs.REPLACE_WITH_YOUR_TOKEN}"

# SSH connection details for the container
SSH_HOST="zero_trust_boundary_ssh"
SSH_PORT="22"
SSH_USER="danielle"
SSH_INITIAL_PASSWORD="YnkXV/6g1+Bd7fKKjfM07g=="

echo "==> Setting up Vault OS Secrets Engine for SSH host management"
echo ""

# Step 1: Verify OS secrets engine is enabled
echo "==> Step 1: Verifying OS secrets engine is enabled..."
if vault secrets list | grep -q "^os/"; then
    echo "✓ OS secrets engine is already enabled at path: os/"
else
    echo "✗ OS secrets engine is not enabled. Please run setup_vault_os_plugin.sh first"
    exit 1
fi

# Step 2: Configure SSH connection to the host
echo ""
echo "==> Step 2: Configuring SSH connection to host..."
vault write os/config/ssh-host \
    host="${SSH_HOST}" \
    port="${SSH_PORT}" \
    username="${SSH_USER}" \
    password="${SSH_INITIAL_PASSWORD}"

echo "✓ SSH connection configured for ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"

# Step 3: Create a role for password rotation
echo ""
echo "==> Step 3: Creating role for password management..."
vault write os/roles/danielle-role \
    host="ssh-host" \
    username="${SSH_USER}" \
    ttl="1h" \
    max_ttl="24h"

echo "✓ Role 'danielle-role' created with 1h TTL"

# Step 4: Test password rotation
echo ""
echo "==> Step 4: Testing password rotation..."
echo "Generating new credentials for danielle..."
NEW_CREDS=$(vault read -format=json os/creds/danielle-role)

if [ $? -eq 0 ]; then
    echo "✓ Successfully generated new credentials!"
    echo ""
    echo "New credentials:"
    echo "$NEW_CREDS" | jq -r '.data | "Username: \(.username)\nPassword: \(.password)"'
    echo ""
    echo "Note: The password has been automatically rotated on the SSH host."
    echo "The old password (${SSH_INITIAL_PASSWORD}) is no longer valid."
else
    echo "✗ Failed to generate credentials"
    exit 1
fi

# Step 5: Verify the configuration
echo ""
echo "==> Step 5: Verifying configuration..."
vault read os/config/ssh-host

echo ""
echo "==> Setup complete! 🎉"
echo ""
echo "Usage:"
echo "  # Get new credentials (rotates password):"
echo "  vault read os/creds/danielle-role"
echo ""
echo "  # View current configuration:"
echo "  vault read os/config/ssh-host"
echo ""
echo "  # List all roles:"
echo "  vault list os/roles"
echo ""
echo "Important: Each time you read os/creds/danielle-role, the password is rotated!"

# Made with Bob
