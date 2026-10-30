# Running the automated workshop

Use Python 3.12–3.14, Terraform >=1.10,<2, Node.js for static checks, and either Docker with Compose v2 >=2.24,<3 (plugin or standalone docker-compose), or Podman using that external Compose v2 provider. The checked local environment uses Python 3.14. Python 3.15 is currently incompatible with the pinned Ansible release.

```sh
cp .env.example .env  # only for a new checkout; preserve your existing .env
# Set VAULT_LICENSE in .env before starting a Vault lab.
make deps
make doctor RUNTIME=podman
make labs
make prepare LAB=01 RUNTIME=podman
make verify LAB=01 RUNTIME=podman
make prepare LAB=02 RUNTIME=podman
# Solve it manually, or apply its reference outcome:
make resolve lab 02 RUNTIME=podman
make status RUNTIME=podman
make down RUNTIME=podman
```

`make down` stops an instance and keeps everything, so `make up` resumes it. `make reset` puts it back to square one: it deletes the instance's containers, volumes, networks, built images, learner code, Vault data and unseal keys. It asks you to type the instance name; in scripts, pass `CONFIRM=<instance>`. Other instances, your root `.env` and the tracked source are untouched.

`make up` creates a fresh baseline or resumes a known reference stage; it never silently returns a later instance to wired. Existing edited learner code is protected; resume its selected services directly through Compose.

`make` alone prints help. Use one action per invocation. IDs are two digits. `make resolve LAB=03` and `make resolve lab 03` are aliases, including under parallel Make. Mixed spellings, multiple actions and unknown IDs fail before runtime dispatch. `RUNTIME=auto` works only when exactly one engine is reachable. If Docker points at Podman's compatibility socket, choose one explicitly.

## Instance files and ports

Default INSTANCE is `workshop`, PORT_BASE is `18000`. Each instance has a `zt-<INSTANCE>` Compose project and separate named volumes. Set both variables for a second instance, for example `INSTANCE=student-two PORT_BASE=19000`. A student instance is an operational convenience, not a hostile multi-tenant isolation boundary.

| Endpoint | PORT_BASE offset | Default |
| --- | --- | --- |
| Backend | +0 | http://127.0.0.1:18000 |
| Vault | +20 | http://127.0.0.1:18020 |
| PostgreSQL | +32 | 127.0.0.1:18032 |
| Keycloak | +82 | http://127.0.0.1:18082 |
| Frontend | +88 | http://localhost:18088 |
| LDAP | +89 | 127.0.0.1:18089 |

Learners edit `.build/<INSTANCE>/backend/connector.js`. The original `backend/connector.js` and root `.env` are preserved. Runtime environment, recovery material, automation tokens and Terraform state are private under `.secrets/<INSTANCE>/`; do not publish that directory. Public completion summaries do not contain credentials. Source support files are staged from `backend/` during reconciliation, so keep connector exercise edits in the instance workspace.

## License and configuration precedence

This matches `../../vault_reference/scripts/compose.sh`: Compose loads tracked `config/defaults.env` first, then your root `.env`, and passes `${VAULT_LICENSE}` directly to the Vault server and Agent environments. Shell overrides follow Compose precedence. No license file is generated, mounted or required by the new path. The default `VAULT_IMAGE` matches vault_reference's `docker.io/hashicorp/vault-enterprise:2.0.3-ent`; override the pin in `.env` when necessary. The legacy Compose license mounts are unchanged. Other legacy database/backend variables in root .env do not override the new instance: it uses deterministic workshop baseline credentials and its private generated backend.env, so the wired exercise remains reproducible.

The dispatcher removes inherited COMPOSE_FILE, COMPOSE_PROFILES and COMPOSE_PROJECT_NAME to keep each invocation scoped. It does not source .env as shell code, print resolved Compose configuration, copy your license into Terraform, or import the original workshop environment. Optional `VAULT_EDITION=community` uses Vault 1.21.4 for non-Enterprise feature testing; use a separate INSTANCE for a different edition.

## Prepare, solve and verify

`prepare NN` converges the previous completed stage, leaving the current exercise to the learner. For 01, preparation establishes the wired source-inspection baseline. A previous lab that already passes live verification is preserved, including equivalent manual code. Repeating the same prepare preserves in-progress edits. Preparing an already solved lab or moving backward is refused rather than silently deleting state.

`resolve NN` reconciles the reference outcome and runs every required behavioral probe. It refuses unknown learner connector edits. Use `OVERWRITE=1` only when deliberately replacing those edits; a private backup is saved first. Lab dependencies are cumulative; a direct forward jump provisions the required feature closure.

`verify NN` checks running behavior without changing desired configuration, adopting resources, restarting services or replacing files. It may issue short-lived probe login tokens/database leases, revoke its own leases, and create/delete a uniquely named CIBA probe order. Credential lifecycle checks can take up to 150 seconds. It accepts an equivalent manual connector rather than checking its checksum. It requires the standard workshop API paths, role names and role-ID inputs in the instance backend.env.

Authenticated user-role selection in the existing JWT examples remains application-enforced. Read endpoints, `/ask` and the UI's data access panel apply the same classifications: the connector's trust level, capped by the caller's role. Row-level security enforces this in PostgreSQL only for `orders`; the other tables rely on the application filter. The backend exchanges its configured LDAP user's JWT with Vault. CIBA is an application approval gate; Vault does not independently prove approval. Invalid tokens on protected CIBA endpoints are rejected; existing optional-auth read endpoints can fall back to anonymous access. This migration does not claim to redesign those boundaries.

## Bootstrap and recovery

`make bootstrap` starts just Vault and establishes custody/automation identities for manual exercises, without enabling application mounts. `make unseal` only unseals an existing initialized instance. Vault's live state is checked every time; a saved recovery file is never treated as proof of initialization. An initialized instance with missing `.secrets/<INSTANCE>/init.json`, or a fresh volume with stale recovery material, fails safely. Restore matching storage and recovery files before retrying.

Expired scoped automation credentials are repaired through private bootstrap custody; runtime AppRole secret IDs are reused while valid. Root is retained as private recovery material and is not delivered to the application. `down` stops automation project containers and preserves volumes. Moving an instance backward to a chosen lab is unsupported: use `make reset` to start it again from nothing, or a fresh INSTANCE/PORT_BASE to keep it.

## Manual resource adoption

`verify` does not require Terraform import. If manually solving created a mount/policy that a later resolve would own, `make resolve` detects the collision and stops. Inspect it, then run `make adopt LAB=NN` with the same instance/runtime settings. Adoption checks mount types and KV version, imports only declared workshop objects and displays the structural plan. It never applies that plan. Review it before running resolve. Repeating a partial import is safe; incompatible mounts are refused.

`make plan LAB=NN` reports desired structural differences; `make drift LAB=NN` fails for differences as well as execution errors. These are Terraform checks only. Operational Ansible drift and behavioral outcomes need repeat-run/live verification. Local state is protected and generated outside the source root. Provider authentication comes from a private scoped token in the subprocess environment, not Terraform variables/resources.

## Fixtures, extensions and legacy scripts

Initial schema and the tracked `data/fixtures` data (six fictional users, all four classifications) are loaded in a transaction only into empty application tables. To pick up changed fixtures or frontend source, run `make reset` or use a fresh INSTANCE: populated tables are preserved, and local images are built only when missing. Existing populated tables are preserved; missing fixtures fail setup instead of generating random data. A DB migration row records the initial schema version. Subsequent schema changes need a new reviewed migration; deleting a local receipt does not trigger data truncation.

Ollama, Boundary, OS rotation, LDAP admin and MinIO remain optional through the original Compose/scripts path. The new application lab chain does not start them. Do not operate both automation and legacy script configuration against the same instance. Legacy scripts are retained until the release validation gate passes; they are not invoked by new playbooks. Labs 04 and 07 use `data/connector.lab-approle.js` and `data/connector.lab-agent-dynamic.js`; `data/connector.approle.js` and `data/connector.agent-dynamic.js` keep their original behaviour for `scripts/switch_connector.sh`.

## Validation

`make check` runs manifest, Python, YAML, JavaScript, Make-dispatch, safety, Agent, Ansible and Terraform checks. Run `automation/live.py` with an explicit `validation-*` instance to exercise sequential labs and strict zero-change repeat resolves. Live logs are private. See [validation](validation.md) for actual evidence and limits.

## Reproducing special acceptance scenarios

Use a fresh `validation-*` instance and an unused port base for each scenario. These deliberately manipulate only their own disposable instance and never delete persistent volumes. Logs and non-secret result summaries are saved privately.

```sh
.venv/bin/python automation/scenarios.py baseline --runtime podman --instance validation-baseline-new --port-base 28000
.venv/bin/python automation/scenarios.py manual --runtime podman --instance validation-manual-new --port-base 29000
.venv/bin/python automation/scenarios.py recovery --runtime podman --instance validation-recovery-new --port-base 30000
.venv/bin/python automation/scenarios.py drift-jump --runtime podman --instance validation-jump-new --port-base 31000
```

The manual scenario creates a real AppRole solution outside Terraform, verifies it, imports its structure, protects/replaces its edited connector explicitly and exercises sealed restart. Recovery revokes only its own automation credential, checks data/identity preservation and tests missing-custody/backward refusal and refusal of an unconfirmed reset. Drift-jump adds a temporary deny-only policy difference, verifies detection/repair, then resolves the missing lab-10 dependency closure.
