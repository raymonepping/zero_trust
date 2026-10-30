# Decisions

Confirmed: both tools from the start; preserve ten labs; support Docker and Podman; separate prepare, resolve and verify.

Defaults: Vault learning remains primary; one named instance per target/project; extensions remain opt-in through legacy Compose. Automation instances have distinct volume names and configurable ports, but this is not a multi-tenant security boundary.

Preparation of 01 creates the wired source-inspection baseline. For NN>01 the initial prepare converges NN-1. A private preparation receipt allows repeat prepare to preserve work; it does not certify completion. Preparing an already solved/currently later lab is refused. Resolving later labs satisfies their declared dependencies; lower-level transitions are refused when higher structure exists. Selective destructive rollback is deliberately unsupported; use a new INSTANCE/PORT_BASE for a clean exercise environment.

Learners edit the generated instance workspace, never the original connector. Resolution refuses unrecognized changes unless OVERWRITE=1 explicitly requests a private backup and replacement. Verification grades behavior without source hashes. New automation does not auto-adopt the original runtime. Imports are explicit and compare remote structure first.

Root token custody remains private recovery material, used only for bootstrap/credential repair. Routine configuration uses separate scoped automation tokens; repeated runs validate existing credentials rather than issue replacements. Terraform owns no secret values. Verify may create bounded login tokens/DB leases for probes, with cleanup; it does not reconcile configuration.

JWT roles remain application-enforced with a backend Vault identity, matching source. End-user-bound Vault tokens and cryptographic binding of CIBA approval to credential issuance are a separate security redesign. Do not describe the existing approval gate as a Vault-enforced gate.

License follow-up: the user identified `VAULT_LICENSE` in the existing root `.env` and requested the vault_reference approach. The implementation now loads config/defaults.env then .env through Compose and passes VAULT_LICENSE directly to Vault/Agent. Generated license-file delivery was removed. No source `.env` or reference-project file is edited.

Provider permissions: auth backend reads use both sys/mounts/auth/<name> and its tune subpath. These paths have read-only access. An attempted additional update/sudo tuning grant was rejected by automatic approval review and was not applied. Existing mount create permissions remain separately scoped. A failed provider post-create read can taint a valid mount; explicit adoption checks its exact remote type before clearing that failed-create taint, without replacement.

Custom Ansible modules contain transactional fixture loading, credential custody, compare-before-write Vault APIs, per-DN LDAP commands, field-scoped Keycloak reconciliation and portable Compose state inspection. They never execute the old setup scripts. Native builtins cover files, templates, waits, facts, assertions and Terraform process execution. This avoids requiring python-ldap system headers or assuming Docker collection compatibility with every Podman provider. Unit, syntax, lint and live probes are required for these project modules.

The final Terraform bootstrap policy grants read-only access to every tune metadata endpoint. Fresh KV and auth creation are validated separately from existing-state drift checks; no tuning write/sudo grant is needed by the declared untuned resources.
