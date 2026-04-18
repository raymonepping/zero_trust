# Vault OS Secrets Engine - Linux Password Rotation

Complete guide for managing Linux user passwords with HashiCorp Vault's OS Secrets Engine.

## Overview

The Vault OS Secrets Engine automates password management for local Linux user accounts. It provides:

- **Automatic Password Rotation**: Passwords rotate on a defined schedule
- **Manual Rotation**: On-demand password changes
- **Password Policies**: Enforce complexity requirements
- **Audit Trail**: Track all password changes with version history
- **SSH Integration**: Direct SSH connectivity for password management

## Architecture

```
┌─────────────────┐         ┌──────────────────┐         ┌─────────────────┐
│  Vault Server   │────────▶│  SSH Connection  │────────▶│  Linux Server   │
│  (Container)    │  SSH    │  (net-data)      │ chpasswd│  (Ubuntu)       │
│                 │         │                  │         │                 │
│  OS Secrets     │         │  IP: Dynamic     │         │  User: danielle │
│  Engine         │         │  Port: 22        │         │  Password: ***  │
└─────────────────┘         └──────────────────┘         └─────────────────┘
```

## Prerequisites

- Vault Enterprise 2.0+ with OS Secrets Engine plugin
- Ubuntu SSH server (container: `zero_trust_boundary_ssh`)
- Network connectivity between Vault and SSH server (`net-data` network)
- User account on Linux server (default: `danielle`)

## Quick Start

### 1. Initial Setup

Run the automated setup script:

```bash
./scripts/setup_os_secrets_engine.sh
```

This script will:
- ✅ Auto-detect SSH container IP address
- ✅ Reset password to initial value
- ✅ Enable and configure OS secrets engine
- ✅ Create password policy
- ✅ Configure SSH host
- ✅ Create managed account
- ✅ Verify setup

**Expected Output**:
```
==========================================
  Vault OS Secrets Engine - Setup
==========================================

==> Step 1: Getting SSH container IP address
✓ SSH Container IP: 10.89.3.90

==> Step 2: Resetting password in SSH container
✓ Password reset to initial value

...

==========================================
  Setup Complete! ✓
==========================================
```

### 2. Verify Configuration

Run the verification script:

```bash
./scripts/verify_linux_rotation.sh
```

This script will:
- ✅ Check OS secrets engine status
- ✅ Verify host configuration
- ✅ Verify account configuration
- ✅ Read current credentials
- ✅ Test password on SSH host
- ✅ Trigger manual rotation
- ✅ Verify new password works

**Expected Output**:
```
==========================================
  Vault OS Secrets Engine - Verification
==========================================

...

==========================================
  All checks passed! ✓
==========================================
```

## Manual Commands

### Environment Setup

```bash
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='hvs.REPLACE_WITH_YOUR_TOKEN'
```

### Read Current Password

```bash
vault read os/hosts/ssh-host1/accounts/danielle/creds
```

**Output**:
```
Key                    Value
---                    -----
created_time           2026-04-18T15:56:54Z
last_vault_rotation    2026-04-18T15:56:54Z
next_vault_rotation    2026-04-18T15:57:50Z
password               stakrmgsyxsafltxhhbk
ttl                    2s
username               danielle
version                2
```

### Trigger Manual Rotation

```bash
vault write -f os/hosts/ssh-host1/accounts/danielle/rotate
```

### View Account Configuration

```bash
vault read os/hosts/ssh-host1/accounts/danielle
```

### List All Accounts

```bash
vault list os/hosts/ssh-host1/accounts
```

### View Host Configuration

```bash
vault read os/hosts/ssh-host1
```

### View Password Policy

```bash
vault read sys/policies/password/rhel-policy
```

## Configuration Details

### Password Policy

**File**: `/tmp/password_policy.hcl`

```hcl
length = 20
rule "charset" {
   charset = "abcdefghijklmnopqrstuvwxyz"
   min-chars = 1
}
```

- **Length**: 20 characters
- **Character Set**: Lowercase letters (a-z)
- **Minimum**: At least 1 lowercase character

### Host Configuration

```bash
vault write os/hosts/ssh-host1 \
    address=<auto-detected-ip> \
    port=22
```

- **Host Name**: `ssh-host1`
- **Address**: Auto-detected from container (e.g., `10.89.3.90`)
- **Port**: `22` (SSH default)
- **SSH Host Key Trust**: Enabled on first use

### Account Configuration

```bash
vault write os/hosts/ssh-host1/accounts/danielle \
    rotation_period="1m" \
    username="danielle" \
    password_policy="rhel-policy" \
    password="YnkXV/6g1+Bd7fKKjfM07g=="
```

- **Rotation Period**: `1m` (1 minute for demo; use `30d` or `90d` in production)
- **Username**: `danielle`
- **Password Policy**: `rhel-policy`
- **Initial Password**: `YnkXV/6g1+Bd7fKKjfM07g==`

## Scripts Reference

### setup_os_secrets_engine.sh

**Purpose**: Complete automated setup of OS Secrets Engine

**Location**: `./scripts/setup_os_secrets_engine.sh`

**Features**:
- Auto-detects SSH container IP from Docker network
- Resets password to known initial value
- Configures all Vault components
- Verifies setup works end-to-end
- Idempotent (can be run multiple times)

**Usage**:
```bash
./scripts/setup_os_secrets_engine.sh
```

**When to Use**:
- Initial setup
- After container restarts (IP changes)
- To reset configuration to known state

### verify_linux_rotation.sh

**Purpose**: Comprehensive verification and testing

**Location**: `./scripts/verify_linux_rotation.sh`

**Features**:
- Checks all components are configured
- Reads current credentials
- Tests password authentication on SSH host
- Triggers manual rotation
- Verifies new password works
- Provides detailed summary

**Usage**:
```bash
./scripts/verify_linux_rotation.sh
```

**When to Use**:
- After setup to verify everything works
- To test rotation functionality
- For troubleshooting
- As a health check

## Workflow Examples

### Complete Setup and Verification

```bash
# Run both scripts in sequence
./scripts/setup_os_secrets_engine.sh && ./scripts/verify_linux_rotation.sh
```

### After Container Restart

```bash
# Containers restarted, IP may have changed
podman compose restart vault boundary-ssh

# Wait for services to be ready
sleep 10

# Unseal Vault
./scripts/unseal_vault.sh

# Reconfigure with new IP
./scripts/setup_os_secrets_engine.sh
```

### Check Current Password

```bash
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='hvs.REPLACE_WITH_YOUR_TOKEN'

vault read os/hosts/ssh-host1/accounts/danielle/creds
```

### Force Password Rotation

```bash
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='hvs.REPLACE_WITH_YOUR_TOKEN'

# Trigger rotation
vault write -f os/hosts/ssh-host1/accounts/danielle/rotate

# Read new password
vault read os/hosts/ssh-host1/accounts/danielle/creds
```

### Test SSH Access

```bash
# Get current password
PASSWORD=$(vault read -format=json os/hosts/ssh-host1/accounts/danielle/creds | jq -r '.data.password')

# Test SSH from host machine
ssh -p 2222 danielle@localhost
# Enter password when prompted

# Or test from within container
podman exec zero_trust_boundary_ssh su - danielle -c "echo '${PASSWORD}' | sudo -S whoami"
```

## Monitoring and Maintenance

### Check Rotation Status

```bash
vault read os/hosts/ssh-host1/accounts/danielle
```

Look for:
- `last_vault_rotation`: When password was last changed
- `next_vault_rotation`: When next automatic rotation will occur
- `current_version`: Current password version number

### View Rotation History

Password versions increment with each rotation:
- Version 1: Initial password
- Version 2: First rotation
- Version 3: Second rotation
- etc.

### Automatic Rotation

Vault automatically rotates passwords based on `rotation_period`:

```bash
# Current setting: 1 minute (demo)
rotation_period="1m"

# Production recommendations:
rotation_period="30d"  # 30 days
rotation_period="90d"  # 90 days
```

## Troubleshooting

### Issue: "context deadline exceeded"

**Cause**: Vault cannot connect to SSH server

**Solutions**:
1. Check SSH container is running:
   ```bash
   podman ps | grep boundary_ssh
   ```

2. Verify network connectivity:
   ```bash
   podman inspect zero_trust_boundary_ssh --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}: {{$conf.IPAddress}} {{end}}'
   ```

3. Reconfigure with correct IP:
   ```bash
   ./scripts/setup_os_secrets_engine.sh
   ```

### Issue: "plugin is shut down"

**Cause**: Plugin crashed or was disabled

**Solution**:
```bash
# Disable and re-enable
vault secrets disable os
vault secrets enable -path=os -plugin-version="0.1.0+ent" vault-plugin-secrets-os

# Reconfigure
./scripts/setup_os_secrets_engine.sh
```

### Issue: "failed to authenticate"

**Cause**: Password mismatch between Vault and Linux system

**Solution**:
```bash
# Reset password in container
podman exec zero_trust_boundary_ssh bash -c 'echo "danielle:YnkXV/6g1+Bd7fKKjfM07g==" | chpasswd'

# Reconfigure Vault
./scripts/setup_os_secrets_engine.sh
```

### Issue: IP Address Changed

**Cause**: Container restarted and got new IP

**Solution**:
```bash
# Simply re-run setup script (auto-detects new IP)
./scripts/setup_os_secrets_engine.sh
```

## Security Considerations

### Production Recommendations

1. **Rotation Period**: Use longer periods (30-90 days)
   ```bash
   rotation_period="30d"
   ```

2. **Password Policy**: Strengthen requirements
   ```hcl
   length = 32
   rule "charset" {
      charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()"
      min-chars = 1
   }
   rule "uppercase" {
      charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      min-chars = 2
   }
   rule "lowercase" {
      charset = "abcdefghijklmnopqrstuvwxyz"
      min-chars = 2
   }
   rule "digits" {
      charset = "0123456789"
      min-chars = 2
   }
   rule "special" {
      charset = "!@#$%^&*()"
      min-chars = 2
   }
   ```

3. **SSH Host Keys**: Provide explicit host keys instead of trust-on-first-use
   ```bash
   # Get host key
   ssh-keyscan -t ed25519 -p 22 10.89.3.90
   
   # Configure with explicit key
   vault write os/hosts/ssh-host1 \
       address=10.89.3.90 \
       port=22 \
       ssh_host_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGq..."
   ```

4. **Access Control**: Use Vault policies to restrict access
   ```hcl
   # Allow reading credentials only
   path "os/hosts/ssh-host1/accounts/danielle/creds" {
     capabilities = ["read"]
   }
   ```

5. **Audit Logging**: Enable Vault audit logging
   ```bash
   vault audit enable file file_path=/vault/audit/audit.log
   ```

### Network Security

- SSH server is on internal network (`net-boundary-private`)
- Vault connects via shared network (`net-data`)
- External access only through Boundary or port forwarding
- No direct SSH exposure to internet

## Advanced Usage

### Multiple Accounts

```bash
# Add another user
vault write os/hosts/ssh-host1/accounts/admin \
    rotation_period="7d" \
    username="admin" \
    password_policy="rhel-policy" \
    password="initial-password"

# List all accounts
vault list os/hosts/ssh-host1/accounts
```

### Multiple Hosts

```bash
# Add another host
vault write os/hosts/ssh-host2 \
    address=10.89.3.91 \
    port=22

# Configure account on new host
vault write os/hosts/ssh-host2/accounts/danielle \
    rotation_period="30d" \
    username="danielle" \
    password_policy="rhel-policy" \
    password="initial-password"
```

### Custom Rotation Schedules

```bash
# Rotate on specific schedule (cron-like)
vault write os/hosts/ssh-host1/accounts/danielle \
    rotation_schedule="0 2 * * 0"  # Every Sunday at 2 AM
    rotation_window=3600            # 1-hour window
```

## Integration with Boundary

The OS Secrets Engine can be integrated with HashiCorp Boundary for just-in-time credential injection:

1. Configure Boundary credential store pointing to Vault
2. Create credential library for OS secrets
3. Attach to Boundary target
4. Users get fresh credentials for each session

See Boundary documentation for details.

## References

- [Vault OS Secrets Engine Documentation](https://developer.hashicorp.com/vault/docs/secrets/os)
- [Password Policies](https://developer.hashicorp.com/vault/docs/concepts/password-policies)
- [Troubleshooting Guide](./VAULT_OS_PLUGIN_TROUBLESHOOTING.md)

## Support

For issues or questions:
1. Check the [Troubleshooting Guide](./VAULT_OS_PLUGIN_TROUBLESHOOTING.md)
2. Review Vault logs: `podman logs zero_trust_vault`
3. Run verification script: `./scripts/verify_linux_rotation.sh`
4. Check SSH server logs: `podman logs zero_trust_boundary_ssh`

---

*Last Updated: 2026-04-18*  
*Version: 1.0*