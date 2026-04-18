# Vault OS Secrets Engine - Automated Linux Password Rotation

This guide demonstrates how to use HashiCorp Vault's OS secrets engine plugin to automate password management for local Linux accounts in the Zero Trust workshop environment.

## Overview

The OS secrets engine plugin automates:
- Password rotation based on defined policies
- Password complexity enforcement
- Password rotation history tracking
- Batch password rotation during security incidents
- Compliance through centralized management

## Prerequisites

- Vault Enterprise 2.0.0 or later (✅ Running in workshop)
- Ubuntu SSH container (✅ Available as boundary-ssh)
- Valid Vault Enterprise license
- Vault token with appropriate permissions

## Quick Start

### 1. Ensure Required Services Are Running

```bash
# Start Vault
./scripts/start_services.sh --security

# Start SSH target
./scripts/start_services.sh --targets

# Check status
./scripts/start_services.sh --status
```

### 2. Set Environment Variables

```bash
# Set Vault address
export VAULT_ADDR="http://localhost:8200"

# Set Vault token (use your actual token)
export VAULT_TOKEN="your-vault-token"
```

### 3. Run the Setup Script

```bash
./scripts/setup_vault_os_plugin.sh
```

This script will:
1. ✅ Check prerequisites
2. ✅ Download and register the OS secrets engine plugin
3. ✅ Create a password policy (20 chars, mixed case, numbers, symbols)
4. ✅ Configure the secrets engine
5. ✅ Configure the SSH host (boundary-ssh at localhost:2222)
6. ✅ Configure the managed account (boundary user)
7. ✅ Test manual password rotation

## Usage

### Read Current Credentials

```bash
vault read os/hosts/boundary-ssh/accounts/boundary/creds
```

Output:
```
Key                    Value
---                    -----
created_time           2026-04-17T12:00:00Z
last_vault_rotation    2026-04-17T12:05:00Z
next_vault_rotation    2026-04-17T12:10:00Z
password               xYz9!aBc@dEf#gHi$jKl
ttl                    4m30s
username               boundary
version                3
```

### Manually Rotate Password

```bash
vault write -f os/hosts/boundary-ssh/accounts/boundary/rotate
```

### Check Account Configuration

```bash
vault read os/hosts/boundary-ssh/accounts/boundary
```

### Test SSH Access

```bash
# Get the current password
PASSWORD=$(vault read -field=password os/hosts/boundary-ssh/accounts/boundary/creds)

# SSH into the container
ssh -p 2222 boundary@localhost
# Enter the password when prompted
```

## Password Policy

The workshop uses a password policy named `workshop-policy` with the following requirements:

- **Length**: 20 characters
- **Lowercase letters**: At least 1
- **Uppercase letters**: At least 1
- **Numbers**: At least 1
- **Special characters**: At least 1 (!@#$%^&*)

### View Password Policy

```bash
vault read sys/policies/password/workshop-policy
```

### Modify Password Policy

Edit the policy and update:

```bash
cat > /tmp/new_policy.hcl <<EOF
length = 24
rule "charset" {
    charset = "abcdefghijklmnopqrstuvwxyz"
    min-chars = 2
}
rule "charset" {
    charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    min-chars = 2
}
rule "charset" {
    charset = "0123456789"
    min-chars = 2
}
rule "charset" {
    charset = "!@#$%^&*"
    min-chars = 2
}
EOF

vault write sys/policies/password/workshop-policy policy=@/tmp/new_policy.hcl
```

## Rotation Configuration

### Current Settings

- **Rotation Period**: 5 minutes (demo setting)
- **Automatic Rotation**: Enabled
- **Password Policy**: workshop-policy

### Change Rotation Period

For production use, set longer rotation periods:

```bash
# 30 days
vault write os/hosts/boundary-ssh/accounts/boundary \
    rotation_period="30d"

# 90 days
vault write os/hosts/boundary-ssh/accounts/boundary \
    rotation_period="90d"
```

### Disable Automatic Rotation

```bash
vault write os/hosts/boundary-ssh/accounts/boundary \
    disable_automated_rotation=true
```

## Managing Multiple Accounts

### Add Another User

First, create the user in the SSH container:

```bash
podman exec -it zero_trust_boundary_ssh useradd -m -s /bin/bash newuser
podman exec -it zero_trust_boundary_ssh bash -c "echo 'newuser:initialpassword' | chpasswd"
```

Then configure it in Vault:

```bash
vault write os/hosts/boundary-ssh/accounts/newuser \
    rotation_period="30d" \
    username="newuser" \
    password_policy="workshop-policy" \
    password="initialpassword"
```

### List All Accounts

```bash
vault list os/hosts/boundary-ssh/accounts
```

### Remove an Account

```bash
vault delete os/hosts/boundary-ssh/accounts/newuser
```

## Monitoring and Auditing

### Check Rotation History

```bash
# View account details including rotation timestamps
vault read os/hosts/boundary-ssh/accounts/boundary

# Key fields:
# - last_vault_rotation: When password was last rotated
# - next_vault_rotation: When next rotation will occur
# - current_version: Number of rotations performed
```

### Audit Logs

Vault audit logs will contain all password rotation events. Enable audit logging:

```bash
vault audit enable file file_path=/vault/audit/audit.log
```

## Troubleshooting

### Plugin Not Found

If the plugin download fails, manually download it:

```bash
# Check latest version at:
# https://releases.hashicorp.com/vault-plugin-secrets-os/

# Download manually
wget https://releases.hashicorp.com/vault-plugin-secrets-os/0.1.0-rc1+ent/vault-plugin-secrets-os_0.1.0-rc1+ent_linux_amd64.zip

# Extract to plugins directory
unzip vault-plugin-secrets-os_0.1.0-rc1+ent_linux_amd64.zip -d plugins/

# Register manually
vault plugin register -sha256=$(sha256sum plugins/vault-plugin-secrets-os | cut -d' ' -f1) secret vault-plugin-secrets-os
```

### SSH Connection Fails

1. Verify the SSH container is running:
   ```bash
   podman ps | grep boundary_ssh
   ```

2. Check if the password is correct:
   ```bash
   vault read os/hosts/boundary-ssh/accounts/boundary/creds
   ```

3. Test SSH connectivity:
   ```bash
   ssh -v -p 2222 boundary@localhost
   ```

### Password Rotation Not Working

1. Check account configuration:
   ```bash
   vault read os/hosts/boundary-ssh/accounts/boundary
   ```

2. Verify automatic rotation is enabled:
   ```bash
   # Should show disable_automated_rotation: false
   vault read os/hosts/boundary-ssh/accounts/boundary
   ```

3. Check Vault logs:
   ```bash
   podman logs zero_trust_vault
   ```

## Security Best Practices

1. **Use Long Rotation Periods in Production**: 30-90 days instead of 5 minutes
2. **Implement Strong Password Policies**: Enforce complexity requirements
3. **Enable Audit Logging**: Track all password access and rotation events
4. **Use Vault Policies**: Restrict who can read credentials and trigger rotations
5. **Monitor Rotation Failures**: Set up alerts for failed rotations
6. **Regular Compliance Checks**: Review rotation history and policy adherence

## Integration with Boundary

The OS secrets engine can be integrated with Boundary for dynamic credential injection:

1. Boundary connects to the target using Vault-managed credentials
2. Credentials are automatically rotated by Vault
3. Users never see the actual passwords
4. All access is logged and audited

## Workshop Scenarios

### Scenario 1: Emergency Password Rotation

Simulate a security incident requiring immediate password rotation:

```bash
# Rotate all accounts immediately
vault write -f os/hosts/boundary-ssh/accounts/boundary/rotate

# Verify new password
vault read os/hosts/boundary-ssh/accounts/boundary/creds
```

### Scenario 2: Compliance Audit

Demonstrate compliance with password policies:

```bash
# Show password policy
vault read sys/policies/password/workshop-policy

# Show rotation history
vault read os/hosts/boundary-ssh/accounts/boundary

# Show all managed accounts
vault list os/hosts/boundary-ssh/accounts
```

### Scenario 3: Break-Glass Access

Use Vault-managed credentials for emergency access:

```bash
# Get current credentials
PASSWORD=$(vault read -field=password os/hosts/boundary-ssh/accounts/boundary/creds)

# Access the system
ssh -p 2222 boundary@localhost
```

## Additional Resources

- [Vault OS Secrets Engine Documentation](https://developer.hashicorp.com/vault/docs/secrets/os)
- [Password Policies](https://developer.hashicorp.com/vault/docs/concepts/password-policies)
- [Vault Enterprise Features](https://www.hashicorp.com/products/vault/pricing)

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review Vault logs: `podman logs zero_trust_vault`
3. Verify SSH container logs: `podman logs zero_trust_boundary_ssh`

---

**Made with Bob** 🤖