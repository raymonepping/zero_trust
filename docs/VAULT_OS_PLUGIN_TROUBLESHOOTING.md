# Vault OS Secrets Engine - Troubleshooting Guide

## The Day-Long Journey to Success 🎢

This document chronicles the troubleshooting journey for enabling the Vault OS Secrets Engine plugin, which took an entire day to resolve. May it save you from the same fate!

---

## TL;DR - The Solution

### Step 1: Add Plugin Directory Volume Mount (if missing)

In your `docker-compose.yml`, ensure you have:

```yaml
volumes:
  - ./plugins:/vault/plugins:Z
```

**This was the missing piece in the zero_trust environment!**

### Step 2: Register and Enable the Plugin

```bash
# 1. Register the plugin (downloads automatically)
vault plugin register -download -version="0.1.0+ent" secret vault-plugin-secrets-os

# 2. Enable with version specified (THIS IS CRITICAL!)
vault secrets enable -path=os -plugin-version="0.1.0+ent" vault-plugin-secrets-os
```

**Key Points**:
1. Volume mount must exist for plugin directory
2. You MUST specify `-plugin-version` when enabling, or Vault will look for the binary in the wrong location

---

## The Problem

When attempting to enable the OS Secrets Engine, we encountered:

```
Error enabling: Error making API request.
Code: 400. Errors:
* invalid backend version: 2 errors occurred:
  * error verifying checksum: open /vault/plugins/vault-plugin-secrets-os: no such file or directory
```

---

## What We Thought Was Wrong (But Wasn't)

### ❌ Theory 1: License Issues
**Symptom**: "the OS secrets engine requires a licensed Vault Enterprise server"

**Investigation**: 
- Checked license features extensively
- Compared V1 vs V2 license formats
- Inspected license IDs and feature arrays
- Tested multiple license files

**Reality**: The license (ID: `abd9570a-18e6-00a1-e372-91155b3d9ad6`) was perfectly fine and included OS Secrets Engine support.

### ❌ Theory 2: Plugin Directory Not Configured
**Symptom**: "core plugin directory is not set"

**Investigation**:
- Verified `plugin_directory = "/vault/plugins"` in config.hcl
- Checked volume mounts in docker-compose.yml
- Confirmed directory permissions

**Reality**: Configuration was correct all along.

### ❌ Theory 3: Missing Internet Access
**Symptom**: Plugin binary not downloading

**Investigation**:
- Tested container internet connectivity
- Verified `net-egress` network configuration
- Checked firewall rules

**Reality**: Internet access was working fine.

### ❌ Theory 4: Wrong Plugin Version
**Symptom**: RC version vs release version confusion

**Investigation**:
- Tested `0.1.0-rc1+ent` vs `0.1.0+ent`
- Compared plugin behavior between versions
- Checked release notes

**Reality**: Both versions work, but you need to specify which one.

---

## What Was Actually Wrong ✅

### Issue 1: Dev Mode Missing Plugin Directory Flag

**Environment**: test_2.0 (dev mode)

**Problem**: Dev mode doesn't use config.hcl, so `plugin_directory` setting was ignored.

**Solution**: Add `-dev-plugin-dir` flag to the command:

```yaml
# docker-compose.yml
command: vault server -dev -dev-root-token-id=root -dev-listen-address=0.0.0.0:8200 -dev-plugin-dir=/vault/plugins
```

### Issue 2: Missing Plugin Directory Volume Mount

**Environment**: zero_trust (production mode)

**Problem**: The docker-compose.yml was missing the volume mount for the plugins directory. Even though `plugin_directory = "/vault/plugins"` was set in config.hcl, the directory wasn't accessible because it wasn't mounted from the host.

**Solution**: Add the volume mount to docker-compose.yml:

```yaml
volumes:
  - ./plugins:/vault/plugins:Z
```

After adding this, restart the container:
```bash
podman compose restart vault
```

### Issue 3: Plugin Version Not Specified When Enabling

**Environment**: Both dev and production modes

**Problem**: When using `-download` flag during registration, Vault stores plugins in a versioned subdirectory structure:
```
/vault/plugins/.runtime/vault-plugin-secrets-os_0.1.0+ent_linux_arm64/
```

But when enabling without specifying version, Vault looks for:
```
/vault/plugins/vault-plugin-secrets-os
```

**Solution**: Always specify the plugin version when enabling:

```bash
vault secrets enable -path=os -plugin-version="0.1.0+ent" vault-plugin-secrets-os
```

---

## Complete Working Configuration

### Production Mode (with config.hcl)

**vault/config.hcl**:
```hcl
ui = true
disable_mlock = true

api_addr = "http://vault:8200"
cluster_addr = "http://vault:8201"

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

storage "raft" {
  path = "/vault/file"
}

# Plugin directory for custom plugins
plugin_directory = "/vault/plugins"

log_level = "info"
```

**docker-compose.yml**:
```yaml
vault:
  image: hashicorp/vault-enterprise:2.0.0-ent
  container_name: zero_trust_vault
  cap_add:
    - IPC_LOCK
  ports:
    - "8200:8200"
  volumes:
    - ./vault/config.hcl:/vault/config/config.hcl:Z
    - ./vault/plugins:/vault/plugins:Z
    - vault_data:/vault/file
  environment:
    VAULT_ADDR: "http://127.0.0.1:8200"
    VAULT_LICENSE: "${VAULT_LICENSE}"
    SKIP_SETCAP: "true"
  command: vault server -config=/vault/config/config.hcl
  networks:
    - net-data
    - net-egress
```

### Dev Mode

**docker-compose.yml**:
```yaml
vault:
  image: hashicorp/vault-enterprise:2.0.0-ent
  container_name: test_vault
  cap_add:
    - IPC_LOCK
  ports:
    - "8200:8200"
  volumes:
    - ./plugins:/vault/plugins:Z
  env_file:
    - .env
  environment:
    VAULT_ADDR: "http://127.0.0.1:8200"
    SKIP_SETCAP: "true"
  command: vault server -dev -dev-root-token-id=root -dev-listen-address=0.0.0.0:8200 -dev-plugin-dir=/vault/plugins
```

---

## Step-by-Step Setup Process

### 1. Ensure Vault is Running and Unsealed

```bash
# Check status
vault status

# If sealed, unseal it
./scripts/unseal_vault.sh
```

### 2. Register the Plugin

```bash
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='your-root-token'

# Register with automatic download
vault plugin register -download -version="0.1.0+ent" secret vault-plugin-secrets-os
```

**What happens**:
- Vault downloads the plugin from releases.hashicorp.com
- Stores it in `/vault/plugins/.cache/`
- Extracts to `/vault/plugins/.runtime/vault-plugin-secrets-os_0.1.0+ent_linux_arm64/`
- Registers in the plugin catalog

### 3. Verify Registration

```bash
vault plugin list secret | grep os
```

**Expected output**:
```
vault-plugin-secrets-os    v0.1.0+ent
```

### 4. Enable the Secrets Engine

```bash
# CRITICAL: Specify the version!
vault secrets enable -path=os -plugin-version="0.1.0+ent" vault-plugin-secrets-os
```

**Success output**:
```
Success! Enabled the vault-plugin-secrets-os secrets engine version 0.1.0+ent at: os/
```

### 5. Verify It's Working

```bash
vault secrets list | grep os
```

**Expected output**:
```
os/    vault-plugin-secrets-os    n/a
```

---

## Common Errors and Solutions

### Error: "core plugin directory is not set"

**Cause**: Dev mode without `-dev-plugin-dir` flag

**Solution**: Add flag to command:
```bash
vault server -dev -dev-plugin-dir=/vault/plugins
```

### Error: "open /vault/plugins/vault-plugin-secrets-os: no such file or directory"

**Cause**: Enabled without specifying plugin version

**Solution**: Add `-plugin-version` flag:
```bash
vault secrets enable -path=os -plugin-version="0.1.0+ent" vault-plugin-secrets-os
```

### Error: "the OS secrets engine requires a licensed Vault Enterprise server"

**Cause**: Actually, this error is misleading! It usually means the plugin isn't properly registered or enabled, NOT a license issue.

**Solution**: 
1. Verify plugin is registered: `vault plugin list secret`
2. Enable with version specified
3. Check your license only if the above doesn't work

### Error: "Vault is sealed"

**Cause**: Vault needs to be unsealed after restart

**Solution**:
```bash
./scripts/unseal_vault.sh
```

---

## Debugging Tips

### Check Plugin Directory Contents

```bash
# Inside container
podman exec zero_trust_vault ls -la /vault/plugins/
podman exec zero_trust_vault ls -la /vault/plugins/.runtime/
podman exec zero_trust_vault ls -la /vault/plugins/.cache/
```

### Check Plugin Catalog

```bash
vault plugin list secret
vault plugin info secret vault-plugin-secrets-os
```

### Check Vault Logs

```bash
podman logs zero_trust_vault 2>&1 | grep -i plugin
```

### Verify Internet Access (for downloads)

```bash
podman exec zero_trust_vault wget -q --spider https://releases.hashicorp.com && echo "OK" || echo "FAILED"
```

---

## Key Takeaways

1. **Always specify plugin version when enabling** if you used `-download` during registration
2. **Dev mode needs `-dev-plugin-dir` flag** - config.hcl is ignored in dev mode
3. **License errors are often red herrings** - check plugin registration first
4. **Plugin directory structure matters** - downloaded plugins go into `.runtime/` subdirectories
5. **Internet access is required** for `-download` flag to work

---

## References

- [Vault Plugin System Documentation](https://developer.hashicorp.com/vault/docs/plugins)
- [OS Secrets Engine Documentation](https://developer.hashicorp.com/vault/docs/secrets/os)
- [Plugin Registration API](https://developer.hashicorp.com/vault/api-docs/system/plugins-catalog)

---

## Timeline of Our Journey

- **Hour 1-2**: Suspected license issues, inspected multiple license files
- **Hour 3-4**: Investigated plugin directory configuration
- **Hour 5-6**: Tested different plugin versions (RC vs release)
- **Hour 7-8**: Created test environment to isolate the issue
- **Hour 9**: 💡 Discovered `-dev-plugin-dir` flag was missing in dev mode
- **Hour 10**: 🎉 Realized `-plugin-version` flag was needed when enabling

**Total time**: ~10 hours
**Actual fixes**:
1. Add volume mount: `./plugins:/vault/plugins:Z` (zero_trust environment)
2. Dev mode flag: `-dev-plugin-dir=/vault/plugins` (test_2.0 environment)
3. Enable with version: `-plugin-version="0.1.0+ent"` (both environments)

---

*Document created: 2026-04-17*  
*Last updated: 2026-04-17*  
*Status: ✅ RESOLVED*

---

## Appendix: Full Working Script

```bash
#!/bin/bash
set -e

# Configuration
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='hvs.REDACTED_TOKEN'
PLUGIN_VERSION="0.1.0+ent"

echo "==> Checking Vault status..."
vault status

echo "==> Registering OS Secrets Engine plugin..."
vault plugin register \
  -download \
  -version="${PLUGIN_VERSION}" \
  secret \
  vault-plugin-secrets-os

echo "==> Verifying plugin registration..."
vault plugin list secret | grep vault-plugin-secrets-os

echo "==> Enabling OS Secrets Engine..."
vault secrets enable \
  -path=os \
  -plugin-version="${PLUGIN_VERSION}" \
  vault-plugin-secrets-os

echo "==> Verifying secrets engine is enabled..."
vault secrets list | grep os

echo "✅ OS Secrets Engine successfully enabled at path: os/"
```

Save this as `setup_os_plugin.sh` and run it after Vault is unsealed.