# Changelog

## Unreleased

- Add manifest-driven Make, Ansible and Terraform automation for the ten-stage workshop, with separate preparation, reference resolution and behavioral verification.
- Use the vault_reference defaults/.env pattern for direct Vault Enterprise license delivery.
- Add protected learner workspaces, explicit resource adoption, scoped bootstrap identities and repeat-run/live acceptance checks.
- Add lab-only references `connector.lab-approle.js` (static KV) and `connector.lab-agent-dynamic.js` (Agent file); the original `connector.approle.js` and `connector.agent-dynamic.js` keep their legacy behaviour.
- Seed automated instances from tracked `data/fixtures`: six fictional users and all four classifications.
- Cap readable classifications by the caller's role on every read endpoint and `/ask`, apply the trust filter to `/orders`, and report the same result in the UI's data access panel, which now refreshes immediately on sign-in and sign-out.
- Make `make reset` delete one whole instance after typed confirmation, or `CONFIRM=<instance>` in scripts.
- Show masked Compose failure output and name missing `.env` or `config/defaults.env` before starting.
- Rebuild the frontend in Vault daylight glass as a four-view console (Overview, Data, Approvals, Ask), with a credential ladder and a live per-identity Data view. Publish images 1.8.19.


All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
### Changed
### Deprecated
### Removed
### Fixed
### Security
