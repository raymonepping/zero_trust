#!/bin/bash
set -e

# Setup SSH Certificate-Based Authentication
# Configures Vault SSH CA and adds your macOS public key to the Ubuntu container

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "=========================================="
echo "  SSH Certificate-Based Auth Setup"
echo "=========================================="
echo ""

# Configuration
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN="${VAULT_TOKEN:-hvs.REPLACE_WITH_YOUR_TOKEN}"
SSH_CONTAINER="zero_trust_boundary_ssh"
SSH_USER="danielle"

# Step 1: Check if SSH public key exists on macOS
echo -e "${BLUE}==> Step 1: Checking for SSH public key${NC}"
if [ ! -f ~/.ssh/id_rsa.pub ] && [ ! -f ~/.ssh/id_ed25519.pub ]; then
    echo -e "${YELLOW}No SSH key found. Generating new ED25519 key...${NC}"
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "$(whoami)@$(hostname)"
    PUB_KEY_FILE=~/.ssh/id_ed25519.pub
elif [ -f ~/.ssh/id_ed25519.pub ]; then
    PUB_KEY_FILE=~/.ssh/id_ed25519.pub
else
    PUB_KEY_FILE=~/.ssh/id_rsa.pub
fi

PUB_KEY=$(cat $PUB_KEY_FILE)
echo -e "${GREEN}✓ Using public key: ${PUB_KEY_FILE}${NC}"
echo ""

# Step 2: Enable Vault SSH secrets engine
echo -e "${BLUE}==> Step 2: Configuring Vault SSH secrets engine${NC}"
if vault secrets list | grep -q "^ssh/"; then
    echo -e "${YELLOW}SSH secrets engine already enabled${NC}"
else
    vault secrets enable ssh
    echo -e "${GREEN}✓ SSH secrets engine enabled${NC}"
fi
echo ""

# Step 3: Configure SSH CA
echo -e "${BLUE}==> Step 3: Configuring SSH Certificate Authority${NC}"
if vault read ssh/config/ca > /dev/null 2>&1; then
    echo -e "${YELLOW}SSH CA already configured${NC}"
else
    vault write ssh/config/ca generate_signing_key=true
    echo -e "${GREEN}✓ SSH CA configured${NC}"
fi
echo ""

# Step 4: Create SSH role for signing certificates
echo -e "${BLUE}==> Step 4: Creating SSH role${NC}"
vault write ssh/roles/boundary-ssh \
    key_type=ca \
    ttl=30m \
    allow_user_certificates=true \
    allowed_users="danielle,ubuntu,root"
echo -e "${GREEN}✓ SSH role 'boundary-ssh' created${NC}"
echo ""

# Step 5: Get Vault's CA public key
echo -e "${BLUE}==> Step 5: Getting Vault CA public key${NC}"
VAULT_CA_KEY=$(vault read -field=public_key ssh/config/ca)
echo -e "${GREEN}✓ Vault CA public key retrieved${NC}"
echo ""

# Step 6: Add Vault CA to Ubuntu container's trusted keys
echo -e "${BLUE}==> Step 6: Adding Vault CA to Ubuntu container${NC}"
podman exec ${SSH_CONTAINER} bash -c "
mkdir -p /etc/ssh
echo '${VAULT_CA_KEY}' > /etc/ssh/trusted-user-ca-keys.pem
chmod 644 /etc/ssh/trusted-user-ca-keys.pem

# Update sshd_config to trust the CA
if ! grep -q 'TrustedUserCAKeys' /etc/ssh/sshd_config; then
    echo 'TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem' >> /etc/ssh/sshd_config
    # Reload SSH config (SIGHUP)
    pkill -HUP sshd || true
fi
"
echo -e "${GREEN}✓ Vault CA added to Ubuntu container${NC}"
echo -e "${YELLOW}Note: SSH config updated. Container may need restart for changes to take full effect.${NC}"
echo ""

# Step 7: Add your macOS public key to danielle's authorized_keys
echo -e "${BLUE}==> Step 7: Adding your public key to ${SSH_USER}'s authorized_keys${NC}"
podman exec ${SSH_CONTAINER} bash -c "
mkdir -p /home/${SSH_USER}/.ssh
echo '${PUB_KEY}' >> /home/${SSH_USER}/.ssh/authorized_keys
chmod 700 /home/${SSH_USER}/.ssh
chmod 600 /home/${SSH_USER}/.ssh/authorized_keys
chown -R ${SSH_USER}:${SSH_USER} /home/${SSH_USER}/.ssh
"
echo -e "${GREEN}✓ Public key added to ${SSH_USER}'s authorized_keys${NC}"
echo ""

# Step 8: Get SSH container IP
echo -e "${BLUE}==> Step 8: Getting SSH container IP${NC}"
SSH_IP=$(podman inspect ${SSH_CONTAINER} --format '{{range $net, $conf := .NetworkSettings.Networks}}{{if eq $net "zero_trust_net-data"}}{{$conf.IPAddress}}{{end}}{{end}}')
echo -e "${GREEN}✓ SSH Container IP: ${SSH_IP}${NC}"
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}  Setup Complete! ✓${NC}"
echo "=========================================="
echo ""
echo "SSH Certificate-Based Authentication is now configured!"
echo ""
echo "Option 1: SSH with Vault-signed certificate"
echo "  1. Sign your SSH key with Vault:"
echo "     vault write -field=signed_key ssh/sign/boundary-ssh \\"
echo "       public_key=@${PUB_KEY_FILE} > ~/.ssh/id_ed25519-cert.pub"
echo ""
echo "  2. SSH to the container:"
echo "     ssh -i ~/.ssh/id_ed25519 ${SSH_USER}@${SSH_IP}"
echo ""
echo "Option 2: SSH with your public key (already added)"
echo "     ssh -i ~/.ssh/id_ed25519 ${SSH_USER}@${SSH_IP}"
echo ""
echo "Option 3: Use Boundary for brokered access"
echo "     boundary connect ssh -target-id=<target-id>"
echo ""
echo "Note: Certificates are valid for 30 minutes and can be renewed."
echo ""

# Made with Bob