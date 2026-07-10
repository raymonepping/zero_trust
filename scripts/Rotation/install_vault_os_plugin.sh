#!/bin/bash
set -e

# Install Vault OS Secrets Engine Plugin
# Downloads and installs the vault-plugin-secrets-os binary

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=========================================="
echo -e "  Install Vault OS Secrets Plugin"
echo -e "==========================================${NC}\n"

# Configuration
PLUGIN_VERSION="0.1.0-rc3+ent"  # Enterprise version
PLUGIN_DIR="../../plugins"
PLUGIN_NAME="vault-plugin-secrets-os"

# Detect OS and architecture
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

# Convert architecture names
case $ARCH in
    x86_64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    *)
        echo -e "${RED}✗ Unsupported architecture: $ARCH${NC}"
        exit 1
        ;;
esac

echo -e "${BLUE}System Information:${NC}"
echo "  OS: $OS"
echo "  Architecture: $ARCH"
echo ""

# Create plugins directory if it doesn't exist
mkdir -p "$PLUGIN_DIR"

# Download URL (adjust based on actual release location)
DOWNLOAD_URL="https://releases.hashicorp.com/vault-plugin-secrets-os/${PLUGIN_VERSION}/vault-plugin-secrets-os_${PLUGIN_VERSION}_${OS}_${ARCH}.zip"

echo -e "${BLUE}Step 1: Downloading plugin...${NC}"
echo "URL: $DOWNLOAD_URL"
echo ""

# Try to download
if command -v curl &> /dev/null; then
    curl -L -o "/tmp/${PLUGIN_NAME}.zip" "$DOWNLOAD_URL" 2>&1 | grep -v "^  "
elif command -v wget &> /dev/null; then
    wget -O "/tmp/${PLUGIN_NAME}.zip" "$DOWNLOAD_URL"
else
    echo -e "${RED}✗ Neither curl nor wget found${NC}"
    exit 1
fi

if [ $? -ne 0 ]; then
    echo -e "${RED}✗ Download failed${NC}"
    echo ""
    echo -e "${YELLOW}Alternative: Manual Installation${NC}"
    echo "1. Download the plugin from:"
    echo "   https://releases.hashicorp.com/vault-plugin-secrets-os/"
    echo ""
    echo "2. Extract and place the binary in:"
    echo "   $PLUGIN_DIR/$PLUGIN_NAME"
    echo ""
    echo "3. Make it executable:"
    echo "   chmod +x $PLUGIN_DIR/$PLUGIN_NAME"
    echo ""
    echo "4. Restart Vault container:"
    echo "   docker restart zero_trust_vault"
    exit 1
fi

echo -e "${GREEN}✓ Download complete${NC}"
echo ""

# Extract
echo -e "${BLUE}Step 2: Extracting plugin...${NC}"
unzip -o "/tmp/${PLUGIN_NAME}.zip" -d "$PLUGIN_DIR/"
rm "/tmp/${PLUGIN_NAME}.zip"

if [ ! -f "$PLUGIN_DIR/$PLUGIN_NAME" ]; then
    echo -e "${RED}✗ Plugin binary not found after extraction${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Plugin extracted${NC}"
echo ""

# Make executable
echo -e "${BLUE}Step 3: Setting permissions...${NC}"
chmod +x "$PLUGIN_DIR/$PLUGIN_NAME"
echo -e "${GREEN}✓ Plugin is executable${NC}"
echo ""

# Calculate SHA256
echo -e "${BLUE}Step 4: Calculating SHA256...${NC}"
PLUGIN_SHA=$(shasum -a 256 "$PLUGIN_DIR/$PLUGIN_NAME" | cut -d' ' -f1)
echo "SHA256: $PLUGIN_SHA"
echo ""

# Restart Vault to pick up the new plugin
echo -e "${BLUE}Step 5: Restarting Vault container...${NC}"
if command -v podman &> /dev/null; then
    podman restart zero_trust_vault
elif command -v docker &> /dev/null; then
    docker restart zero_trust_vault
else
    echo -e "${YELLOW}⚠ Could not find docker or podman${NC}"
    echo "Please restart Vault manually"
fi

echo -e "${GREEN}✓ Vault restarted${NC}"
echo ""

# Wait for Vault to be ready
echo -e "${BLUE}Step 6: Waiting for Vault to be ready...${NC}"
export VAULT_ADDR='http://127.0.0.1:8200'
for i in {1..30}; do
    if vault status > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Vault is ready${NC}"
        break
    fi
    echo -n "."
    sleep 1
done
echo ""

# Register plugin
echo -e "${BLUE}Step 7: Registering plugin in Vault...${NC}"
vault plugin register \
    -sha256="$PLUGIN_SHA" \
    -command="$PLUGIN_NAME" \
    secret $PLUGIN_NAME

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Plugin registered${NC}"
else
    echo -e "${RED}✗ Plugin registration failed${NC}"
    exit 1
fi
echo ""

# Enable secrets engine
echo -e "${BLUE}Step 8: Enabling OS Secrets Engine...${NC}"
vault secrets enable -path=os $PLUGIN_NAME

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ OS Secrets Engine enabled${NC}"
else
    echo -e "${YELLOW}⚠ Secrets engine may already be enabled${NC}"
fi
echo ""

# Create password policy
echo -e "${BLUE}Step 9: Creating password policy...${NC}"
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

echo -e "${GREEN}✓ Password policy created${NC}"
echo ""

echo -e "${BLUE}=========================================="
echo -e "  Installation Complete!"
echo -e "==========================================${NC}\n"

echo -e "${GREEN}Plugin Details:${NC}"
echo "  • Binary: $PLUGIN_DIR/$PLUGIN_NAME"
echo "  • SHA256: $PLUGIN_SHA"
echo "  • Registered: Yes"
echo "  • Enabled: Yes (at path 'os/')"
echo ""

echo -e "${GREEN}Next Steps:${NC}"
echo "1. Configure SSH host:"
echo "   vault write os/hosts/ssh-host1 address=<container-ip> port=22"
echo ""
echo "2. Add users:"
echo "   ./add_user.sh --username boundary"
echo ""

# Made with Bob
