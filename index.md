# Workshop Docs Index

This file is the documentation map for the Zero Trust Workshop. The root [README.md](./README.md) is the guided lab entry point. This index links to the deeper script and subsystem documents in `./docs`.

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

- [README.md](./README.md)  
  Main workshop overview, architecture, startup flow, and recommended lab order.

- [docs/readme_backend.md](./docs/readme_backend.md)  
  Backend architecture, API behavior, connector integration, and operational notes.

- [docs/readme_frontend.md](./docs/readme_frontend.md)  
  Frontend architecture, runtime behavior, UI flows, and Vite/Docker notes.

- [docs/readme_routes.md](./docs/readme_routes.md)  
  Backend route reference and usage notes for the route test script.

- [docs/readme_switch_connector.md](./docs/readme_switch_connector.md)  
  Detailed explanation of every connector mode and how the progression works.

---

## Core Lab Progression

- [docs/readme_switch_connector.md](./docs/readme_switch_connector.md)  
  Connector progression, prerequisites for each mode, and switching mechanics.

- [docs/readme_backend.md](./docs/readme_backend.md)  
  How the backend enforces auth, resolves credentials, and exposes the workshop API.

- [docs/readme_frontend.md](./docs/readme_frontend.md)  
  How the student-facing UI reflects connector state, trust level, and CIBA workflows.

- [docs/readme_routes.md](./docs/readme_routes.md)  
  Current API route surface, auth expectations, and route smoke-testing behavior.

- [docs/readme_setup_vault.md](./docs/readme_setup_vault.md)  
  How Vault is configured for KV, dynamic credentials, AppRole, JWT, policies, and audit.

- [docs/readme_vault_unseal.md](./docs/readme_vault_unseal.md)  
  How Vault unseal works and how the unseal helper script behaves.

- [docs/readme_vault_login.md](./docs/readme_vault_login.md)  
  Logging into Vault safely and using the CLI during the workshop.

---

## Setup And Identity

- [docs/readme_setup_ldap.md](./docs/readme_setup_ldap.md)  
  How the LDAP directory is populated and used.

- [docs/readme_setup_keycloak.md](./docs/readme_setup_keycloak.md)  
  Keycloak realm, client, federation, and JWT flow setup.

- [docs/readme_setup_ciba_vault.md](./docs/readme_setup_ciba_vault.md)  
  Vault-side setup needed for the CIBA-enabled write flow.

- [docs/readme_setup_ciba_keycloak.md](./docs/readme_setup_ciba_keycloak.md)  
  Keycloak-side CIBA configuration and callback wiring.

---

## Vault And Audit Operations

- [docs/readme_vault_audit.md](./docs/readme_vault_audit.md)  
  Reading and understanding the Vault audit log.

- [docs/readme_vault_audit_rotate.md](./docs/readme_vault_audit_rotate.md)  
  Rotating the Vault audit log safely and managing retention.

---

## Container And Image Operations

- [docs/readme_docker.md](./docs/readme_docker.md)  
  Docker host prerequisites, sizing, ports, storage, and operational commands.

- [docs/readme_podman.md](./docs/readme_podman.md)  
  Podman machine prerequisites, sizing, compatibility notes, and operational commands.

- [docs/readme_inspect_containers.md](./docs/readme_inspect_containers.md)  
  Container resource inspection and Docker disk usage overview.

- [docs/readme_images_build.md](./docs/readme_images_build.md)  
  Build, push, and Compose tag update workflow for workshop images.

- [docs/readme_images_purge.md](./docs/readme_images_purge.md)  
  Local image retention and old-tag cleanup.

---

## Data And Lab Utilities

- [docs/readme_seed_db.md](./docs/readme_seed_db.md)  
  Database seeding and workshop data reset behavior.

- [docs/readme_routes.md](./docs/readme_routes.md)  
  Script and API route reference for validating backend behavior during labs.

---

## Suggested Reading Order

If you are a student running the labs for the first time:

1. [README.md](./README.md)
2. [docs/readme_frontend.md](./docs/readme_frontend.md)
3. [docs/readme_backend.md](./docs/readme_backend.md)
4. [docs/readme_routes.md](./docs/readme_routes.md)
5. [docs/readme_switch_connector.md](./docs/readme_switch_connector.md)
6. [docs/readme_docker.md](./docs/readme_docker.md)
7. [docs/readme_seed_db.md](./docs/readme_seed_db.md)
8. [docs/readme_setup_ldap.md](./docs/readme_setup_ldap.md)
9. [docs/readme_setup_keycloak.md](./docs/readme_setup_keycloak.md)
10. [docs/readme_setup_vault.md](./docs/readme_setup_vault.md)
11. [docs/readme_vault_unseal.md](./docs/readme_vault_unseal.md)

If you are operating or extending the workshop:

1. [README.md](./README.md)
2. [docs/readme_frontend.md](./docs/readme_frontend.md)
3. [docs/readme_backend.md](./docs/readme_backend.md)
4. [docs/readme_routes.md](./docs/readme_routes.md)
5. [docs/readme_switch_connector.md](./docs/readme_switch_connector.md)
6. [docs/readme_docker.md](./docs/readme_docker.md)
7. [docs/readme_podman.md](./docs/readme_podman.md)
8. [docs/readme_inspect_containers.md](./docs/readme_inspect_containers.md)
9. [docs/readme_images_build.md](./docs/readme_images_build.md)
10. [docs/readme_images_purge.md](./docs/readme_images_purge.md)
