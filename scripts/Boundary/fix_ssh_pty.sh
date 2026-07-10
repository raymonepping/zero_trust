#!/bin/bash
set -e

# Fix SSH PTY Allocation for Certificate-Based Auth
# Ensures sshd allows PTY and has proper certificate configuration

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "=========================================="
echo "  Fix SSH PTY Allocation"
echo "=========================================="
echo ""

# Configuration
SSH_CONTAINER="zero_trust_boundary_ssh"

# Step 1: Check if container is running
echo -e "${BLUE}==> Step 1: Checking if SSH container is running${NC}"
if ! podman ps | grep -q ${SSH_CONTAINER}; then
    echo -e "${RED}✗ Container ${SSH_CONTAINER} is not running${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Container is running${NC}"
echo ""

# Step 2: Update sshd_config for certificate-based auth
echo -e "${BLUE}==> Step 2: Updating sshd_config for certificate auth${NC}"
podman exec ${SSH_CONTAINER} bash -c "
# Ensure PTY allocation is allowed
if ! grep -q '^PermitTTY yes' /etc/ssh/sshd_config; then
    echo 'PermitTTY yes' >> /etc/ssh/sshd_config
fi

# Ensure certificate authentication is enabled
if ! grep -q '^PubkeyAuthentication yes' /etc/ssh/sshd_config; then
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
fi

# Ensure the TrustedUserCAKeys is set (should already be there from setup_ssh_ca.sh)
if ! grep -q 'TrustedUserCAKeys' /etc/ssh/sshd_config; then
    echo 'TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem' >> /etc/ssh/sshd_config
fi

# Verify the CA key file exists
if [ ! -f /etc/ssh/trusted-user-ca-keys.pem ]; then
    echo 'ERROR: /etc/ssh/trusted-user-ca-keys.pem not found!'
    exit 1
fi

# Show current sshd_config relevant settings
echo '=== Current SSH Configuration ==='
grep -E '^(PermitTTY|PubkeyAuthentication|TrustedUserCAKeys|PasswordAuthentication|PermitRootLogin)' /etc/ssh/sshd_config || true
"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ sshd_config updated${NC}"
else
    echo -e "${RED}✗ Failed to update sshd_config${NC}"
    exit 1
fi
echo ""

# Step 3: Restart SSH service
echo -e "${BLUE}==> Step 3: Restarting SSH service${NC}"
podman exec ${SSH_CONTAINER} bash -c "
# Send SIGHUP to sshd to reload config
pkill -HUP sshd
sleep 1
# Verify sshd is still running
if pgrep sshd > /dev/null; then
    echo 'SSH service reloaded successfully'
else
    echo 'ERROR: SSH service not running after reload'
    exit 1
fi
"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ SSH service restarted${NC}"
else
    echo -e "${RED}✗ Failed to restart SSH service${NC}"
    exit 1
fi
echo ""

# Step 4: Verify Vault CA is configured
echo -e "${BLUE}==> Step 4: Verifying Vault CA configuration${NC}"
podman exec ${SSH_CONTAINER} bash -c "
if [ -f /etc/ssh/trusted-user-ca-keys.pem ]; then
    echo 'Vault CA public key:'
    head -c 50 /etc/ssh/trusted-user-ca-keys.pem
    echo '...'
else
    echo 'ERROR: Vault CA key not found!'
    exit 1
fi
"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Vault CA is configured${NC}"
else
    echo -e "${RED}✗ Vault CA not configured. Run setup_ssh_ca.sh first${NC}"
    exit 1
fi
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}  SSH PTY Fix Complete! ✓${NC}"
echo "=========================================="
echo ""
echo "SSH is now configured for certificate-based authentication with PTY support"
echo ""
echo "Test your Boundary SSH connection:"
echo "  boundary connect ssh -target-id=<your-target-id>"
echo ""
echo "If you still get PTY errors, check:"
echo "  1. Vault SSH role has correct allowed_users"
echo "  2. Certificate is being properly signed"
echo "  3. Boundary credential library is attached to target"
echo ""

# Made with Bob