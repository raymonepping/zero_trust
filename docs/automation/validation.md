# Migration validation

Validated on 2026-10-30. The ten core application labs are implemented and have passed behavioral verification and zero-change repeat resolution through both configured entrypoints. Native Docker Engine portability is a remaining release gate; the Docker CLI on this host reaches Podman's compatibility API.

## Runtime and tooling

| Component | Tested |
| --- | --- |
| Controller | macOS arm64, Python 3.14 |
| Ansible | ansible-core 2.21.1, project-local environment |
| Lint | ansible-lint 26.9.0, project module_utils loaded for argument inspection |
| Terraform / provider | Terraform 1.14.2, hashicorp/vault 5.9.0 with tracked lockfile |
| Podman | CLI 6.1.4; remote server 5.7.1, Linux arm64/Fedora 43 |
| Compose | Docker Compose 2.39.4, standalone and Podman external-provider entrypoints |
| Vault Enterprise | Default image pin 2.0.3-ent; valid VAULT_LICENSE from the existing root .env |
| Vault Community | 1.21.4, used additionally for adoption/recovery/forward-jump checks |

Docker and Podman entrypoints were selected explicitly and ran separate projects/ports/volumes. They share one underlying engine on this host, so this is not evidence of a native Docker Engine run. No real license, token or credential values are included in this report.

## Lab coverage

“Resolve” is the final successful resolution/behavioral verification for that lab, including corrections found during development. “Repeat” is an actual second reconciliation with Ansible changed=0, followed by behavioral verification. It does not infer idempotency from check mode or a completion marker.

| Lab | Podman resolve | Podman repeat | Docker compatibility resolve | Docker compatibility repeat |
| --- | --- | --- | --- | --- |
| 01 | Passed | Passed, changed=0 | Passed | Passed, changed=0 |
| 02 | Passed | Passed, changed=0 | Passed | Passed, changed=0 |
| 03 | Passed | Passed, changed=0 | Passed | Passed, changed=0 |
| 04 | Passed | Passed, changed=0 | Passed | Passed, changed=0 |
| 05 | Passed | Passed, changed=0 | Passed | Passed, changed=0 |
| 06 | Passed | Passed, changed=0 | Passed | Passed, changed=0 |
| 07 | Passed | Passed, changed=0 | Passed | Passed, changed=0 |
| 08 | Passed | Passed, changed=0 | Passed | Passed, changed=0 |
| 09 | Passed | Passed, changed=0 | Passed | Passed, changed=0 |
| 10 | Passed | Passed, changed=0 | Passed | Passed, changed=0 |

The Agent stage compares application metadata with the rendered file, and its standalone test proves file replacement without network/Vault calls. Lifecycle stages observe a changed lease ID while DB reads continue. Role stages verify authenticated mapping, allowed classifications/row counts, denied viewer table access and denied writes for read identities. CIBA checks pending denial, explicit rejection, approval callback, successful matching write and DB state, then removes only its uniquely named probe order.

## Additional evidence

- 19 Python safety/contract/dispatch tests and the Node Agent replacement test pass. Make aliases dispatch once under sequential and parallel Make; invalid goals never reach runtime discovery.
- Project-local Ansible syntax and lint pass. Python/YAML/JavaScript parsing, Terraform fmt/validate, source credential scanning and new-document link/code-fence checks pass. The CI workflow is added; no remote CI run or push was performed.
- A completely fresh baseline passes without starting Vault or Agent. Explicitly building missing local images before up avoids the first-repeat recreation observed through the compatibility API.
- Manual environment and AppRole solutions pass verification with edited source. Preparing the next lab preserves a previously verified manual solution; repeating preparation preserves in-progress work.
- Explicit adoption imports manually created AppRole structure and displays its plan before later resolution. Failed-create mount taint recovery verifies the exact live mount type and clears bookkeeping without deleting/recreating a mount.
- Sealed restart/unseal succeeds. Expired automation credentials are repaired while application AppRole secret IDs and DB row counts remain unchanged. Missing recovery material, backward transitions and unconfirmed reset requests are refused safely.
- A deny-only policy mutation is detected by drift; explicit resolution repairs it and returns to an empty plan. Forward jumps provision missing database/JWT/role/CIBA dependencies without completing intermediate exercises manually.
- Internal data-network isolation, instance resume after container/network recreation with volumes retained, and both frontend HTML endpoints were exercised.
- Private Terraform state and backups were checked against known local credential values without emitting their contents. Bootstrap tune metadata permissions are read-only; fresh KV/auth structure creation is checked separately from existing-resource plan reads.

The validation instances and their detailed logs were later removed with `make reset`. A non-secret coverage summary is saved in `.build/validation-summary.json`. Use [the usage guide](usage.md) and `automation/live.py` / `automation/scenarios.py` to reproduce the checks with fresh validation instances and free ports. Never operate another session against a scenario's instance while it is running.

## Independent re-validation

A second pass on 2026-10-30 ran the student path on a fresh Podman instance: prepare, verify (must fail from lab 02), resolve, verify, for all ten labs. It then checked repeat resolve, drift, refusals and down/up. After the role, fixture, connector and UI changes it was repeated from empty storage, with the manual scenario, an approval through the browser, screenshots at 1440×900 and 390×844, and axe WCAG 2.1 AA scans with 0 violations on labs 03 and 10. This pass found that a read endpoint leak let support-read users see confidential and restricted rows outside `orders`; the role ceiling now applies there and `verify` checks it.

Known open item: `*.env` in `.gitignore` excludes `config/defaults.env`, so a fresh clone stops at preflight until that file is tracked.

## Limits and release gates

Native Docker Engine, Linux controller and x86_64 live runs remain untested here. Podman providers other than the checked Compose v2 provider are not claimed as supported; preflight requires Compose v2 >=2.24,<3. Python 3.15 is not supported by the pinned Ansible release. Check mode does not establish bootstrap custody, credential validity or complete API reconciliation; use real repeats and live probes.

The JWT examples retain a backend identity exchange plus application-side caller role selection. CIBA approval is enforced by the application, not independently by Vault. Existing optional-auth read endpoints retain anonymous fallback. This migration does not claim caller-bound Vault tokens or a redesign of those application security boundaries.

Selective rollback to a chosen lab is unsupported; `make reset` deletes a whole instance after explicit confirmation. Existing incompatible mounts require explicit review. Existing populated tables are preserved, and schema evolution requires a new reviewed migration. Masked database passwords use private input receipts plus live behavior checks; automatic resolve does not indiscriminately reset a rotated backend password.

Boundary, OS rotation, MinIO, Ollama and LDAP admin remain in the legacy optional path and are not marked migrated or live-validated by this core lab release. Legacy scripts are retained pending the remaining portability/release gates. The original .env, recovery material and runtime are not adopted automatically.

The obsolete preliminary generated license copy was removed. No commit, push or remote deployment was performed.
