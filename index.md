# Workshop Docs Index

This file is the documentation map for the Zero Trust Workshop. The root [README.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/README.md) is the guided lab entry point. This index links to the deeper script and subsystem documents in `./docs`.

---

## Table Of Contents

- [Start Here](#start-here)
- [Core Lab Progression](#core-lab-progression)
- [Setup And Identity](#setup-and-identity)
- [Vault And Audit Operations](#vault-and-audit-operations)
- [Container And Image Operations](#container-and-image-operations)
- [Data And Lab Utilities](#data-and-lab-utilities)
- [Suggested Reading Order](#suggested-reading-order)

---

## Start Here

- [README.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/README.md)  
  Main workshop overview, architecture, startup flow, and recommended lab order.

- [docs/readme_frontend.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_frontend.md)  
  Frontend architecture, runtime behavior, UI flows, and Vite/Docker notes.

- [docs/readme_switch_connector.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_switch_connector.md)  
  Detailed explanation of every connector mode and how the progression works.

---

## Core Lab Progression

- [docs/readme_switch_connector.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_switch_connector.md)  
  Connector progression, prerequisites for each mode, and switching mechanics.

- [docs/readme_frontend.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_frontend.md)  
  How the student-facing UI reflects connector state, trust level, and CIBA workflows.

- [docs/readme_setup_vault.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_setup_vault.md)  
  How Vault is configured for KV, dynamic credentials, AppRole, JWT, policies, and audit.

- [docs/readme_vault_unseal.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_vault_unseal.md)  
  How Vault unseal works and how the unseal helper script behaves.

- [docs/readme_vault_login.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_vault_login.md)  
  Logging into Vault safely and using the CLI during the workshop.

---

## Setup And Identity

- [docs/readme_setup_ldap.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_setup_ldap.md)  
  How the LDAP directory is populated and used.

- [docs/readme_setup_keycloak.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_setup_keycloak.md)  
  Keycloak realm, client, federation, and JWT flow setup.

- [docs/readme_setup_ciba_vault.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_setup_ciba_vault.md)  
  Vault-side setup needed for the CIBA-enabled write flow.

- [docs/readme_setup_ciba_keycloak.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_setup_ciba_keycloak.md)  
  Keycloak-side CIBA configuration and callback wiring.

---

## Vault And Audit Operations

- [docs/readme_vault_audit.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_vault_audit.md)  
  Reading and understanding the Vault audit log.

- [docs/readme_vault_audit_rotate.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_vault_audit_rotate.md)  
  Rotating the Vault audit log safely and managing retention.

---

## Container And Image Operations

- [docs/readme_inspect_containers.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_inspect_containers.md)  
  Container resource inspection and Docker disk usage overview.

- [docs/readme_images_build.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_images_build.md)  
  Build, push, and Compose tag update workflow for workshop images.

- [docs/readme_images_purge.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_images_purge.md)  
  Local image retention and old-tag cleanup.

---

## Data And Lab Utilities

- [docs/readme_seed_db.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_seed_db.md)  
  Database seeding and workshop data reset behavior.

---

## Suggested Reading Order

If you are a student running the labs for the first time:

1. [README.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/README.md)
2. [docs/readme_frontend.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_frontend.md)
3. [docs/readme_switch_connector.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_switch_connector.md)
4. [docs/readme_seed_db.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_seed_db.md)
5. [docs/readme_setup_ldap.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_setup_ldap.md)
6. [docs/readme_setup_keycloak.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_setup_keycloak.md)
7. [docs/readme_setup_vault.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_setup_vault.md)
8. [docs/readme_vault_unseal.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_vault_unseal.md)

If you are operating or extending the workshop:

1. [README.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/README.md)
2. [docs/readme_frontend.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_frontend.md)
3. [docs/readme_switch_connector.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_switch_connector.md)
4. [docs/readme_inspect_containers.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_inspect_containers.md)
5. [docs/readme_images_build.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_images_build.md)
6. [docs/readme_images_purge.md](/Users/raymon.epping/Documents/VSC/HashiCorp/workshop/zero_trust/docs/readme_images_purge.md)
