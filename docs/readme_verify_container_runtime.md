# verify_container_runtime.sh

**Location:** `scripts/verify_container_runtime.sh`  
**Audience:** students and engineers

This script is the outermost runtime preflight for the workshop environment.

It does not verify the Zero Trust workshop application itself. It verifies the container runtime underneath it:

- Docker
- Podman
- and, on macOS, Docker Desktop, Colima, or Podman machine behavior

If this script fails badly, there is no point debugging PostgreSQL, LDAP, Keycloak, Vault, or the frontend yet.

---

## Purpose

The script is designed to answer a simple question:

> Is the container runtime healthy enough to run the workshop stack reliably?

It checks:

- CLI availability
- daemon reachability
- socket or machine state
- basic image pull and container run operations
- Compose support
- storage and disk pressure
- networking and port publishing
- container health states
- image hygiene
- privileged container posture

It can also attempt a limited set of safe corrective actions when `--fix` is used.

---

## Usage

From the repository root:

```bash
./scripts/verify_container_runtime.sh
```

Examples:

```bash
./scripts/verify_container_runtime.sh --runtime docker
./scripts/verify_container_runtime.sh --runtime podman
./scripts/verify_container_runtime.sh --runtime auto --fix
./scripts/verify_container_runtime.sh --runtime podman --verbose
./scripts/verify_container_runtime.sh --runtime docker --json
./scripts/verify_container_runtime.sh --runtime docker --services --ports
```

---

## Command-line options

| Option | Purpose |
|--------|---------|
| `--runtime <docker|podman|auto>` | Select the runtime to test |
| `--fix` | Attempt safe automatic corrections |
| `--services` | Run additional service health checks for common infrastructure ports |
| `--ports` | Perform a deeper host port conflict scan |
| `--verbose` | Print successful checks, not just warnings and failures |
| `--json` | Print a machine-readable JSON summary after the normal output |
| `--help` | Show usage |

Default runtime mode is `auto`.

---

## Runtime selection behavior

### `--runtime docker`

The script verifies Docker only. If `docker` is not installed, it fails immediately.

### `--runtime podman`

The script verifies Podman only. If `podman` is not installed, it fails immediately.

### `--runtime auto`

The script detects which runtime is available and prefers whichever daemon is actually reachable.

If both CLIs are installed:

- Docker is preferred when `docker info` works
- Podman is preferred when Docker is not reachable but `podman info` works

If both CLIs exist but neither daemon is reachable, it warns and defaults to Docker for later checks.

This is useful on developer laptops where both runtimes may be installed.

---

## Important note about Docker contexts and `DOCKER_HOST`

On macOS, it is common to have both Docker Desktop and Podman installed. In that situation, the Docker CLI can be routed to Podman through:

- a Docker context
- `DOCKER_HOST`

That means:

- `docker ps` may actually be showing Podman containers
- `docker version` may report a Podman server

The script reports what the current CLI path is really talking to. That is useful, not a bug.

When diagnosing Docker specifically, check:

```bash
docker context ls
docker context show
echo $DOCKER_HOST
docker version
```

If `DOCKER_HOST` is set, it overrides the active Docker context.

---

## What the script checks

## 1. Runtime Detection

This section confirms whether Docker or Podman is installed and selects the runtime based on your requested mode.

It will:

- fail if the requested runtime binary is missing
- or auto-detect the most usable runtime when `auto` is selected

---

## 2. Binary & Version

This section confirms the runtime CLI actually works.

For Docker, it also checks:

- Docker context
- whether `docker buildx` is available

For Podman, it checks:

- whether Podman remote connections are defined

This is useful because a runtime binary may exist on `PATH` while the actual backend configuration is still broken.

---

## 3. Daemon & Socket

This section checks whether the runtime daemon is reachable.

If the daemon is not reachable:

- Docker Desktop can be started automatically on macOS when `--fix` is used
- Podman machine can be started or initialized on macOS when `--fix` is used

It also checks:

- expected socket location
- server version
- running container count

This is one of the most important sections in the script.

If the daemon is not reachable, later checks are skipped because they would only create noise.

---

## 4. Machine State (macOS)

This section exists only on macOS.

For Docker:

- checks whether Docker Desktop is running
- notes Colima if it is installed

For Podman:

- checks whether a Podman machine exists
- checks whether it is running
- reports machine resources such as CPU, memory, and disk size

This is especially useful when a runtime appears installed but the VM behind it is stopped.

---

## 5. Basic Operations

This section verifies that the runtime can actually do useful work.

It checks:

- `ps`
- `images`
- pull of `hello-world`
- run of `hello-world`

These are simple but important. A runtime can report a version and still fail to pull or run containers.

If `hello-world` cannot run, the runtime is not healthy enough for the workshop.

---

## 6. Compose

This section checks:

- whether Compose is available
- whether it is a native plugin or a legacy standalone implementation

For Docker, the script prefers:

- `docker compose`

For Podman, it prefers:

- `podman compose`

If Compose is missing, the script gives installation suggestions.

---

## 7. Storage

This section checks:

- storage driver
- storage root
- disk usage
- volume count
- dangling volumes
- system disk usage

It also offers safe cleanup suggestions and can prune dangling volumes when `--fix` is used.

Important interpretation points:

- `overlay` or `overlay2` is the preferred storage driver
- `vfs` works, but is usually slower and less suitable for normal development
- high disk usage can cause image pulls, builds, and container startup to fail in misleading ways

For Podman on macOS, storage may live inside the VM, so the script uses `podman system df` rather than host filesystem checks where needed.

---

## 8. Networking

This section checks:

- network count
- existence of the default bridge-like network
- custom networks
- DNS resolution inside a container
- basic host-to-container networking details

For Docker, it expects the default bridge network.

For Podman, it expects the default `podman` network.

This section matters because many "container is up but app cannot connect" problems are actually runtime-level DNS or bridge issues.

---

## 9. Port Checks

This section always reports published container ports from running containers.

When `--ports` is used, it also scans for conflicts on a set of common development and infrastructure ports, including:

- Vault
- Nomad
- Consul
- PostgreSQL
- Redis
- HTTP and HTTPS ports

The script distinguishes between:

- ports used by containers, which is usually fine
- ports already occupied by host processes, which may indicate a conflict

This is useful when a workshop service "starts" but you are actually hitting some unrelated local service on the same port.

---

## 10. Optional Service Health Checks

This section only runs when `--services` is supplied.

It checks a small set of common infrastructure services:

- Vault
- Consul
- Nomad
- PostgreSQL

For HTTP services it performs simple endpoint checks. For PostgreSQL it uses `pg_isready` inside the container when possible.

This section is not workshop-specific. It is a generic infrastructure sanity layer.

---

## 11. Container Health Status

This section inspects running containers and reports:

- `healthy`
- `unhealthy`
- `starting`
- or missing `HEALTHCHECK`

It treats missing healthchecks differently depending on the image:

- for known upstream images like Keycloak and some others, missing healthchecks are informational
- for other images, missing healthchecks are a warning

It also scans recent container logs for severe signals:

- `FATAL`
- `PANIC`
- and, with `--verbose`, also `ERROR`

Some known noisy but expected lines are filtered out so the output stays useful.

---

## 12. Image Provenance

This section inspects the images used by running containers and looks for hygiene issues such as:

- `:latest` tags
- unknown registries
- old image age
- dangling images

It can prune dangling images when `--fix` is used.

This is not just cosmetic. Stale images and floating tags make reproducibility worse.

---

## 13. Privileged Container Detection

This section checks the security posture of running containers.

It flags:

- `--privileged`
- dangerous capabilities like `SYS_ADMIN` or `NET_ADMIN`
- host PID namespace sharing
- host networking
- root user behavior

It intentionally treats some workshop realities carefully:

- `IPC_LOCK` for Vault is not treated as dangerous
- root execution in upstream workshop images is surfaced more softly than real privilege escalation flags

This section is about runtime safety, not just workshop correctness.

---

## Summary Scorecard

The final section computes a health grade based on:

- passes
- warnings
- failures
- and, when `--fix` is used, automatic corrections applied

The grades are:

| Grade | Meaning |
|-------|---------|
| `A` | Healthy |
| `B` | Good |
| `C` | Degraded |
| `D` | Critical |
| `F` | Broken |

This is meant as a fast operator view, not as a replacement for reading the actual findings above it.

### Example of an optimal result

For a healthy Podman setup, a strong result looks like this:

```text
══════════════════════════════════════════════════════
  Summary Scorecard
══════════════════════════════════════════════════════

  Runtime : podman
  Mode    : detect only

  Health Grade
  🟢  A — Healthy
  ████████████████████  100%

  ✔ Pass  : 65
  ⚠ Warn  : 0
  ✘ Fail  : 0
    Total : 65 check(s) run

  ✔ Runtime is healthy and ready.
```

That is the target shape:

- no failures
- no warnings
- all core runtime checks passing
- runtime ready for workshop service verification

---

## JSON output

With `--json`, the script prints a JSON summary containing:

- runtime
- health grade
- score
- pass, warn, fail, and fixed counts
- a flat list of recorded checks

This is useful if you want to:

- archive runtime health checks
- feed results into another tool
- compare Docker and Podman outputs programmatically

---

## What `--fix` actually does

The script only attempts relatively safe corrections. Examples include:

- starting Docker Desktop
- starting or initializing a Podman machine
- pruning dangling volumes
- pruning dangling images
- creating missing default networks in some cases

It does **not** attempt deep destructive repair. It will not, for example:

- wipe your entire runtime state
- remove all images
- remove all volumes
- rewrite Docker or Podman configuration files

That restraint is appropriate. Runtime repair can become destructive very quickly.

---

## Relationship to the workshop verifier scripts

This script is the runtime-level preflight.

After it passes, the next layer is the workshop-service preflight:

- [docs/readme_verify_stack.md](./readme_verify_stack.md)
- [docs/readme_verify_postgresql.md](./readme_verify_postgresql.md)
- [docs/readme_verify_ldap.md](./readme_verify_ldap.md)
- [docs/readme_verify_keycloak.md](./readme_verify_keycloak.md)
- [docs/readme_verify_vault.md](./readme_verify_vault.md)

That separation is important:

1. first prove the runtime is healthy
2. then prove the workshop services are healthy

If you skip step 1, you can waste time debugging application symptoms that are really runtime problems.

---

## Typical workflow

For Podman:

```bash
./scripts/verify_container_runtime.sh --runtime podman
./scripts/verify_stack.sh
```

For Docker:

```bash
unset DOCKER_HOST
docker context use desktop-linux
./scripts/verify_container_runtime.sh --runtime docker
```

Then continue with the workshop-specific verifier scripts.

---

## Troubleshooting guidance

### Docker commands show Podman results

Check:

```bash
docker context ls
docker context show
echo $DOCKER_HOST
docker version
```

If `DOCKER_HOST` is set, it overrides the active context.

### Docker Desktop is open but the daemon is not reachable

This usually means the Desktop backend is hung or not ready yet. The script will surface that as a daemon reachability problem.

### Podman CLI exists but the machine is stopped

The script will catch that in the macOS machine-state section and suggest or perform `podman machine start` depending on mode.

### Networking looks broken

Use:

```bash
./scripts/verify_container_runtime.sh --runtime podman --ports --verbose
```

or the Docker equivalent, then inspect the networking and port sections carefully.

---

## Related documents

- [scripts/verify_container_runtime.sh](../scripts/verify_container_runtime.sh)
- [docs/readme_docker.md](./readme_docker.md)
- [docs/readme_podman.md](./readme_podman.md)
- [docs/readme_verify_stack.md](./readme_verify_stack.md)
- [docs/readme_verify_postgresql.md](./readme_verify_postgresql.md)
- [docs/readme_verify_ldap.md](./readme_verify_ldap.md)
- [docs/readme_verify_keycloak.md](./readme_verify_keycloak.md)
- [docs/readme_verify_vault.md](./readme_verify_vault.md)
