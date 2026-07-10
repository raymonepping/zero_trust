# Boundary Scripts

This folder now has two consolidated entrypoint scripts for Boundary-related setup and maintenance:

- `boundary_access_tools.sh`
- `boundary_admin_tools.sh`

The older one-off scripts are still present, but the intent is to use the two consolidated scripts going forward.

---

## 1. `boundary_access_tools.sh`

This script handles the **operator access path** for the Ubuntu SSH target behind Boundary.

It consolidates the behavior that was previously split across:

- `setup_ssh_ca.sh`
- `fix_vault_ssh_role.sh`
- `fix_ssh_pty.sh`
- `setup_boundary_ssh_target.sh`

### Commands

```bash
./boundary_access_tools.sh bootstrap-ssh
./boundary_access_tools.sh setup-ssh-ca
./boundary_access_tools.sh fix-ssh-role
./boundary_access_tools.sh fix-ssh-pty
./boundary_access_tools.sh setup-ssh-target
```

### What each command does

- `bootstrap-ssh`
  - Runs the full Ubuntu SSH setup sequence end to end:
    1. configure Vault SSH CA
    2. configure the Vault SSH role
    3. fix PTY/CA trust inside the Ubuntu SSH container
    4. create or update the Boundary SSH target

- `setup-ssh-ca`
  - Enables the Vault SSH secrets engine if needed
  - Generates the Vault SSH CA if needed
  - Creates or updates the SSH signing role
  - Installs the Vault CA trust and your local public key into the Ubuntu SSH target

- `fix-ssh-role`
  - Updates the Vault SSH role with PTY-related certificate extensions

- `fix-ssh-pty`
  - Updates `sshd_config` in the Ubuntu SSH target to ensure:
    - `PermitTTY yes`
    - `PubkeyAuthentication yes`
    - `TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem`

- `setup-ssh-target`
  - Authenticates to Boundary
  - Creates or updates the static host catalog, host, and host set
  - Creates or reuses the Vault SSH certificate credential library
  - Creates or updates the SSH target

### Important environment variables

```bash
VAULT_ADDR=http://127.0.0.1:8200
VAULT_TOKEN=...
BOUNDARY_ADDR=http://localhost:9200
BOUNDARY_PASSWORD=Password123!
SSH_CONTAINER=zero_trust_boundary_ssh
SSH_USER=danielle
SSH_ROLE_NAME=boundary-ssh
BOUNDARY_AUTH_METHOD_ID=ampw_8RfTaBwDa2
BOUNDARY_ORG_SCOPE=o_7a1VQLLGUg
BOUNDARY_PROJECT_SCOPE=p_vTsmEn4gLN
BOUNDARY_VAULT_CRED_STORE=csvlt_s1WV97fBZS
BOUNDARY_TARGET_NAME=boundary-ssh-ubuntu
```

### Typical usage

First-time SSH path setup:

```bash
export VAULT_TOKEN=...
export BOUNDARY_PASSWORD=...
./boundary_access_tools.sh bootstrap-ssh
```

If only the target wiring needs to be refreshed:

```bash
export BOUNDARY_PASSWORD=...
./boundary_access_tools.sh setup-ssh-target
```

---

## 2. `boundary_admin_tools.sh`

This script handles **Boundary admin and Vault credential-store maintenance**.

It consolidates the behavior that was previously split across:

- `fix_boundary_vault_policy.sh`
- `update_boundary_vault_token.sh`
- `reset_boundary_admin.sh`

### Commands

```bash
./boundary_admin_tools.sh sync-vault-token
./boundary_admin_tools.sh reset-admin
```

### What each command does

- `sync-vault-token`
  - Applies the configured Vault policy for Boundary
  - Creates a new orphan periodic Vault token
  - Updates the Boundary Vault credential store with that token

- `reset-admin`
  - Uses the Boundary recovery KMS key to reset the admin password
  - Runs the password reset through the Boundary controller container

### Important environment variables

```bash
VAULT_ADDR=http://127.0.0.1:8200
VAULT_TOKEN=...
BOUNDARY_ADDR=http://localhost:9200
BOUNDARY_PASSWORD=Password123!
BOUNDARY_VAULT_CRED_STORE=csvlt_s1WV97fBZS
BOUNDARY_POLICY_FILE=../../vault/policies/boundary-vault-full-policy.hcl
BOUNDARY_POLICY_NAME=boundary-controller
BOUNDARY_PERIOD=720h
BOUNDARY_DB_CONTAINER=zero_trust_boundary_db
BOUNDARY_CONTROLLER_CONTAINER=zero_trust_boundary_controller
BOUNDARY_ADMIN_LOGIN=admin
BOUNDARY_NEW_PASSWORD=admin
BOUNDARY_RECOVERY_KEY=...
```

### Typical usage

Refresh Boundary's Vault token after policy changes:

```bash
export VAULT_TOKEN=...
export BOUNDARY_PASSWORD=...
./boundary_admin_tools.sh sync-vault-token
```

Reset the Boundary admin password:

```bash
export BOUNDARY_RECOVERY_KEY=...
export BOUNDARY_NEW_PASSWORD='NewStrongPassword123!'
./boundary_admin_tools.sh reset-admin
```

---

## Recommended workflow

For SSH access setup:

```bash
export VAULT_TOKEN=...
export BOUNDARY_PASSWORD=...
./boundary_access_tools.sh bootstrap-ssh
```

For ongoing Boundary maintenance:

```bash
./boundary_admin_tools.sh sync-vault-token
./boundary_admin_tools.sh reset-admin
```

---

## Notes

- Both consolidated scripts passed `bash -n` and `shellcheck`
- The old scripts are still available for reference
- The new scripts are intended to be the primary interface going forward
