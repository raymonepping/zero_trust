#!/bin/bash

# Vault OS Secrets Engine Plugin Setup
# Automates Linux password rotation with Vault Enterprise 2.0+

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."
    
    # Check if Vault is running
    if ! podman ps | grep -q zero_trust_vault; then
        print_error "Vault container is not running. Start it with: ./scripts/start_services.sh --security"
        exit 1
    fi
    
    # Check if SSH container is running
    if ! podman ps | grep -q zero_trust_boundary_ssh; then
        print_error "SSH container is not running. Start it with: ./scripts/start_services.sh --targets"
        exit 1
    fi
    
    # Check if VAULT_ADDR is set
    if [ -z "$VAULT_ADDR" ]; then
        print_warning "VAULT_ADDR not set. Using default: http://localhost:8200"
        export VAULT_ADDR="http://localhost:8200"
    fi
    
    # Check if VAULT_TOKEN is set
    if [ -z "$VAULT_TOKEN" ]; then
        print_error "VAULT_TOKEN not set. Please export your Vault token."
        exit 1
    fi
    
    print_success "Prerequisites check passed"
}

# Download and register the OS secrets engine plugin
setup_plugin() {
    print_info "=== Setting up Vault OS Secrets Engine Plugin ==="
    
    # Set plugin version (update this as needed)
    local PLUGIN_VERSION="0.1.0-rc1+ent"
    local PLUGIN_NAME="vault-plugin-secrets-os"
    
    print_info "Using plugin version: $PLUGIN_VERSION"
    
    # Determine architecture for the CONTAINER (always Linux)
    # The plugin runs inside the Vault container, not on the host
    local HOST_ARCH=$(uname -m)
    local ARCH
    
    if [[ "$HOST_ARCH" == "arm64" ]] || [[ "$HOST_ARCH" == "aarch64" ]]; then
        ARCH="linux_arm64"
    else
        ARCH="linux_amd64"
    fi
    
    print_info "Host architecture: $HOST_ARCH"
    print_info "Container architecture: $ARCH (plugin will run in Linux container)"
    
    # Plugin directory
    local PLUGIN_DIR="vault/plugins"
    mkdir -p "$PLUGIN_DIR"
    
    local PLUGIN_FILE="${PLUGIN_DIR}/${PLUGIN_NAME}"
    local DOWNLOAD_URL="https://releases.hashicorp.com/${PLUGIN_NAME}/${PLUGIN_VERSION}/${PLUGIN_NAME}_${PLUGIN_VERSION}_${ARCH}.zip"
    
    # Download plugin if not already present
    if [ ! -f "$PLUGIN_FILE" ]; then
        print_info "Downloading plugin from HashiCorp releases..."
        print_info "URL: $DOWNLOAD_URL"
        
        # Download the zip file
        if ! curl -L -o "/tmp/${PLUGIN_NAME}.zip" "$DOWNLOAD_URL" 2>/dev/null; then
            print_error "Failed to download plugin. Please check:"
            print_error "1. Internet connectivity"
            print_error "2. Plugin version exists: $PLUGIN_VERSION"
            print_error "3. Architecture is correct: $ARCH"
            print_error ""
            print_error "Manual download: $DOWNLOAD_URL"
            exit 1
        fi
        
        # Extract the plugin
        print_info "Extracting plugin..."
        unzip -o "/tmp/${PLUGIN_NAME}.zip" -d "$PLUGIN_DIR" > /dev/null
        chmod +x "$PLUGIN_FILE"
        rm "/tmp/${PLUGIN_NAME}.zip"
        
        print_success "Plugin downloaded and extracted to $PLUGIN_FILE"
    else
        print_info "Plugin already exists at $PLUGIN_FILE"
    fi
    
    # Calculate SHA256 for the plugin
    print_info "Calculating plugin SHA256..."
    local PLUGIN_SHA256=$(shasum -a 256 "$PLUGIN_FILE" | cut -d' ' -f1)
    print_info "SHA256: $PLUGIN_SHA256"
    
    # Register the plugin with Vault
    print_info "Registering plugin with Vault..."
    vault plugin register \
        -sha256="$PLUGIN_SHA256" \
        secret "$PLUGIN_NAME"
    
    print_success "Plugin registered successfully"
    
    # Enable the plugin at the os/ path
    print_info "Enabling plugin at os/ path..."
    if vault secrets list | grep -q "^os/"; then
        print_warning "OS secrets engine already enabled at os/"
    else
        vault secrets enable -path=os "$PLUGIN_NAME"
        print_success "OS secrets engine enabled at os/"
    fi
    
    # Verify the plugin
    print_info "Verifying plugin installation..."
    if vault secrets list | grep -q "^os/"; then
        print_success "Plugin verified successfully"
    else
        print_error "Plugin verification failed"
        exit 1
    fi
}

# Create password policy
create_password_policy() {
    print_info "=== Creating Password Policy ==="
    
    # Create password policy file
    cat > /tmp/password_policy.hcl <<-'EOF'
length = 20
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
    charset = "!@#$%^&*"
    min-chars = 1
}
EOF
    
    # Write the policy to Vault
    print_info "Writing password policy to Vault..."
    vault write sys/policies/password/workshop-policy policy=@/tmp/password_policy.hcl
    
    # Verify the policy
    print_info "Verifying password policy..."
    vault read sys/policies/password/workshop-policy > /dev/null
    print_success "Password policy created: workshop-policy"
    
    # Clean up
    rm /tmp/password_policy.hcl
}

# Configure the secrets engine
configure_secrets_engine() {
    print_info "=== Configuring OS Secrets Engine ==="
    
    vault write "os/config" \
        ssh_host_key_trust_on_first_use=true
    
    print_success "OS secrets engine configured"
}

# Configure the SSH host
configure_host() {
    print_info "=== Configuring SSH Host ==="
    
    # Use localhost and port 2222 for the SSH container
    vault write "os/hosts/boundary-ssh" \
        address=127.0.0.1 \
        port=2222
    
    print_success "Host configured: boundary-ssh (127.0.0.1:2222)"
    
    # List configured hosts
    print_info "Configured hosts:"
    vault list os/hosts
}

# Configure managed account
configure_account() {
    print_info "=== Configuring Managed Account ==="
    
    local USERNAME="boundary"
    local INITIAL_PASSWORD="password"
    local ROTATION_PERIOD="5m"  # 5 minutes for demo, use 30d for production
    
    print_info "Configuring account: $USERNAME"
    print_info "Rotation period: $ROTATION_PERIOD"
    
    vault write os/hosts/boundary-ssh/accounts/$USERNAME \
        rotation_period="$ROTATION_PERIOD" \
        username="$USERNAME" \
        password_policy="workshop-policy" \
        password="$INITIAL_PASSWORD"
    
    print_success "Account configured: $USERNAME"
    
    # Show account details
    print_info "Account details:"
    vault read os/hosts/boundary-ssh/accounts/$USERNAME
}

# Test manual rotation
test_manual_rotation() {
    print_info "=== Testing Manual Password Rotation ==="
    
    local USERNAME="boundary"
    
    # Read initial credentials
    print_info "Initial credentials:"
    vault read os/hosts/boundary-ssh/accounts/$USERNAME/creds
    
    # Trigger manual rotation
    print_info "Triggering manual rotation..."
    vault write -f os/hosts/boundary-ssh/accounts/$USERNAME/rotate
    
    # Read rotated credentials
    print_info "Rotated credentials:"
    vault read os/hosts/boundary-ssh/accounts/$USERNAME/creds
    
    print_success "Manual rotation test completed"
}

# Show usage instructions
show_usage() {
    cat << EOF

${GREEN}=== Vault OS Secrets Engine Setup Complete ===${NC}

${BLUE}Available Commands:${NC}

1. Read current credentials:
   ${YELLOW}vault read os/hosts/boundary-ssh/accounts/boundary/creds${NC}

2. Manually rotate password:
   ${YELLOW}vault write -f os/hosts/boundary-ssh/accounts/boundary/rotate${NC}

3. Check account configuration:
   ${YELLOW}vault read os/hosts/boundary-ssh/accounts/boundary${NC}

4. List all hosts:
   ${YELLOW}vault list os/hosts${NC}

5. List all accounts for a host:
   ${YELLOW}vault list os/hosts/boundary-ssh/accounts${NC}

${BLUE}SSH Access:${NC}
   ${YELLOW}ssh -p 2222 boundary@localhost${NC}
   (Use the password from: vault read os/hosts/boundary-ssh/accounts/boundary/creds)

${BLUE}Notes:${NC}
- Passwords will automatically rotate every 5 minutes (demo setting)
- In production, use longer periods like 30d (30 days)
- The password policy enforces 20-character passwords with mixed case, numbers, and symbols
- Automatic rotation happens in the background

${GREEN}Workshop Ready!${NC} 🚀

EOF
}

# Main execution
main() {
    print_info "=== Vault OS Secrets Engine Plugin Setup ==="
    echo ""
    
    check_prerequisites
    echo ""
    
    setup_plugin
    echo ""
    
    create_password_policy
    echo ""
    
    configure_secrets_engine
    echo ""
    
    configure_host
    echo ""
    
    configure_account
    echo ""
    
    test_manual_rotation
    echo ""
    
    show_usage
}

# Run main function
main "$@"

# Made with Bob