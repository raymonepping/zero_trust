# Script migration inventory

Existing scripts remain intact until live replacements pass. No new playbook executes a legacy setup script.

| Script | Classification / target | Effects and prerequisites |
| --- | --- | --- |
| `scripts/Boundary/assign_user_permissions.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Boundary/boundary_access_tools.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Boundary/boundary_admin_tools.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Boundary/create_boundary_users.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Boundary/fix_boundary_vault_policy.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Boundary/fix_ssh_pty.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Boundary/fix_vault_ssh_role.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Boundary/reset_boundary_admin.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Boundary/setup_boundary_ssh_target.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Boundary/setup_boundary_users.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Boundary/setup_ssh_ca.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Boundary/update_boundary_vault_token.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Rotation/add_user.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Rotation/debug_vault_os.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Rotation/fix_plugin_architecture.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Rotation/install_vault_os_plugin.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Rotation/list_users.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Rotation/reload_vault_os_plugin.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Rotation/restore_vault_os_engine.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Rotation/setup_os_rotation.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Rotation/setup_os_secrets_engine.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Rotation/setup_vault_os_plugin.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Rotation/setup_vault_os_ssh.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Rotation/test_user_password.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/Rotation/verify_linux_rotation.sh` | Extension; retain legacy path | Privileged Boundary/Vault/OS changes; extension-specific runtime and credentials |
| `scripts/audit_log.sh` | Maintenance-only; retain | May build/delete images, generate fixtures, rotate logs or change local files; not a lab dependency |
| `scripts/check_versions.sh` | Maintenance-only; retain | May build/delete images, generate fixtures, rotate logs or change local files; not a lab dependency |
| `scripts/clean_git_history.sh` | Maintenance-only; retain | May build/delete images, generate fixtures, rotate logs or change local files; not a lab dependency |
| `scripts/generate_json_files.sh` | Maintenance-only; retain | May build/delete images, generate fixtures, rotate logs or change local files; not a lab dependency |
| `scripts/inspect_containers.sh` | Maintenance-only; retain | May build/delete images, generate fixtures, rotate logs or change local files; not a lab dependency |
| `scripts/prune_dangling_images.sh` | Maintenance-only; retain | May build/delete images, generate fixtures, rotate logs or change local files; not a lab dependency |
| `scripts/purge_images.sh` | Maintenance-only; retain | May build/delete images, generate fixtures, rotate logs or change local files; not a lab dependency |
| `scripts/rotate_vault_audit.sh` | Maintenance-only; retain | May build/delete images, generate fixtures, rotate logs or change local files; not a lab dependency |
| `scripts/seed_db.sh` | Replace through Ansible/Terraform; retain pending live gate | Truncates/reseeds DB and writes schema/RLS; PostgreSQL and fixtures |
| `scripts/setup_ciba.sh` | Replace through Ansible/Terraform; retain pending live gate | Service/configuration writes; inspect script prerequisites; compare-before-write replacement |
| `scripts/setup_ciba_keycloak.sh` | Replace through Ansible/Terraform; retain pending live gate | Service/configuration writes; inspect script prerequisites; compare-before-write replacement |
| `scripts/setup_images.sh` | Maintenance-only; retain | May build/delete images, generate fixtures, rotate logs or change local files; not a lab dependency |
| `scripts/setup_keycloak.sh` | Replace through Ansible/Terraform; retain pending live gate | Service/configuration writes; inspect script prerequisites; compare-before-write replacement |
| `scripts/setup_ldap.sh` | Replace through Ansible/Terraform; retain pending live gate | Service/configuration writes; inspect script prerequisites; compare-before-write replacement |
| `scripts/setup_structure.sh` | Maintenance-only; retain | May build/delete images, generate fixtures, rotate logs or change local files; not a lab dependency |
| `scripts/setup_vault.sh` | Replace through Ansible/Terraform; retain pending live gate | Mounts/policies/auth/roles; issues secret IDs every run; Vault/psql |
| `scripts/start_services.sh` | Replace through Ansible/Terraform; retain pending live gate | Service/configuration writes; inspect script prerequisites; compare-before-write replacement |
| `scripts/stop_services.sh` | Replace through Ansible/Terraform; retain pending live gate | Service/configuration writes; inspect script prerequisites; compare-before-write replacement |
| `scripts/switch_connector.sh` | Replace through Ansible/Terraform; retain pending live gate | Copies/downloads connector and unconditionally restarts; local runtime |
| `scripts/test_ciba.sh` | Verification reference | Inspect service APIs; some old probes mutate test artifacts; new verifier is independent |
| `scripts/test_routes.sh` | Verification reference | Inspect service APIs; some old probes mutate test artifacts; new verifier is independent |
| `scripts/unseal_vault.sh` | Replace through Ansible/Terraform; retain pending live gate | Requires existing init.txt; uses recovery keys/root token |
| `scripts/validate_openapi_docs.sh` | Verification reference | Inspect service APIs; some old probes mutate test artifacts; new verifier is independent |
| `scripts/vault_login.sh` | Maintenance-only; retain | May build/delete images, generate fixtures, rotate logs or change local files; not a lab dependency |
| `scripts/verify_container_runtime.sh` | Verification reference | Inspect service APIs; some old probes mutate test artifacts; new verifier is independent |
| `scripts/verify_environment.sh` | Verification reference | Inspect service APIs; some old probes mutate test artifacts; new verifier is independent |
| `scripts/verify_keycloak.sh` | Verification reference | Inspect service APIs; some old probes mutate test artifacts; new verifier is independent |
| `scripts/verify_ldap.sh` | Verification reference | Inspect service APIs; some old probes mutate test artifacts; new verifier is independent |
| `scripts/verify_postgresql.sh` | Verification reference | Inspect service APIs; some old probes mutate test artifacts; new verifier is independent |
| `scripts/verify_vault.sh` | Verification reference | Inspect service APIs; some old probes mutate test artifacts; new verifier is independent |

Extract schema SQL from the seeder (exclude TRUNCATE), fixture JSON into parameterized transaction loading, DB creation/revocation SQL into declarative variables, Vault HCL into Terraform policies, LDAP LDIF into entry-level reconciliation, and Keycloak component JSON into Ansible data. Never extract local credentials/licenses.
