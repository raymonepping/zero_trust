# setup_images.sh — Build, Push, and Compose Tag Update Script

**Location:** `scripts/setup_images.sh`

This script builds and pushes the workshop’s custom Docker images, then updates `docker-compose.yml` so the stack points at the newly published version tags.

It handles two images:

- backend
- frontend

It also resets the workshop connector back to the `wired` phase before building, so the published images start from a predictable baseline.

The intended audience is students and engineers who want to understand how the workshop images are produced and how version tags are propagated into the Compose configuration.

---

## What the script does

At a high level, the script performs this sequence:

```text
1. Reset backend/connector.js to the wired connector
2. Build backend image
3. Push backend image
4. Update backend image tag in docker-compose.yml
5. Build frontend image
6. Push frontend image
7. Update frontend image tag in docker-compose.yml
```

When the script completes successfully, both custom images exist in the target registry under the specified version tag, and `docker-compose.yml` points at those exact tags.

---

## Why this script exists

This workshop relies on custom backend and frontend images that evolve over time. Building and tagging them manually is repetitive and error-prone.

The script solves that by standardizing three tasks:

- image build
- image publish
- Compose tag synchronization

Without this script, it would be easy to:

- build one image but forget the other
- push a new tag but leave `docker-compose.yml` pointing at an old version
- publish an image while the backend is still in a later workshop phase instead of the intended clean starting point

The script keeps those steps aligned.

---

## Usage

### Default usage

```bash
./scripts/setup_images.sh
```

Defaults:

- version: `1.0.0`
- Docker user / namespace: `repping`

### Specify a version

```bash
./scripts/setup_images.sh 1.8.20
```

### Specify a version and a Docker namespace

```bash
./scripts/setup_images.sh 1.8.20 your-docker-user
```

The script interprets its positional arguments like this:

```bash
./scripts/setup_images.sh <version> <docker-user>
```

Where:

- `<version>` becomes the image tag
- `<docker-user>` becomes the image repository namespace

---

## Default arguments

At the top of the script:

```bash
VERSION="${1:-1.0.0}"
DOCKER_USER="${2:-repping}"
```

So if you do not pass arguments:

- the image tag becomes `1.0.0`
- the image repository prefix becomes `repping`

That means the backend image defaults to:

```text
repping/zero-trust-backend:1.0.0
```

and the frontend image defaults to:

```text
repping/zero-trust-frontend:1.0.0
```

---

## How it works

### 1. Strict shell behavior

The script starts with:

```bash
set -euo pipefail
```

This is important because the script performs destructive and publish-related actions:

- edits `docker-compose.yml`
- pushes images
- depends on external tools succeeding

If any critical step fails, the script exits immediately instead of continuing in a partially updated state.

---

### 2. Resolve script and compose paths

The script computes:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/../docker-compose.yml"
```

This makes the script location-independent as long as it is run from within the repository tree.

It does not rely on your current shell directory matching the script directory exactly. Instead, it resolves paths relative to the script itself.

---

### 3. Reset connector to `wired`

Before any image builds happen, the script runs:

```bash
"${SCRIPT_DIR}/switch_connector.sh" --replace-with wired
```

This is one of the most important behaviors in the script.

It ensures that:

- `backend/connector.js` is reset to the baseline `wired` connector
- the backend image is built from a consistent workshop starting state
- published images do not accidentally embed a later connector phase such as:
  - dynamic
  - AppRole
  - JWT
  - CIBA

Why this matters:

The workshop’s teaching model assumes participants move through connector phases deliberately. If an image were built while `connector.js` was left in an advanced phase, students would start from the wrong security model.

So the script intentionally normalizes the backend state before publishing.

### Practical implication

Running `setup_images.sh` is not just a build action. It also changes your current local backend connector file back to `wired`.

That is expected behavior, not a side effect or bug.

---

### 4. Define the image build matrix

The script defines:

```bash
IMAGES=(
  "zero-trust-backend:./backend"
  "zero-trust-frontend:./frontend"
)
```

Each entry contains:

- image name
- build context path

The loop then processes each image in order.

For each item:

- `zero-trust-backend` uses `./backend`
- `zero-trust-frontend` uses `./frontend`

This keeps the script compact while avoiding duplicated build logic.

---

### 5. Construct the full image reference

Inside the loop, the script computes:

```bash
FULL_IMAGE="${DOCKER_USER}/${NAME}:${VERSION}"
```

For example, with:

- `DOCKER_USER=repping`
- `NAME=zero-trust-backend`
- `VERSION=1.8.20`

the result is:

```text
repping/zero-trust-backend:1.8.20
```

That same pattern is used for both backend and frontend.

---

### 6. Build and push the image

The core Docker command is:

```bash
docker build \
  --no-cache \
  --platform linux/amd64,linux/arm64 \
  --push \
  -t "${FULL_IMAGE}" \
  "${PATHCTX}"
```

Breaking that down:

#### `--no-cache`

Forces Docker to rebuild every layer from scratch instead of reusing local build cache.

This improves reproducibility and avoids accidentally publishing an image that depends on stale cached layers.

Tradeoff:

- slower builds
- more network and compute usage

#### `--platform linux/amd64,linux/arm64`

Builds a multi-platform image for both:

- `linux/amd64`
- `linux/arm64`

This is useful because workshop participants may run:

- Intel/AMD laptops and servers
- Apple Silicon systems
- mixed CI/CD environments

A multi-platform image means one version tag can serve both architectures cleanly.

#### `--push`

Pushes the built image directly to the registry after build completion.

This means the script is intended for publishing, not just local image generation.

#### `-t "${FULL_IMAGE}"`

Applies the target repository and version tag.

#### `"${PATHCTX}"`

Chooses the build context:

- `./backend`
- `./frontend`

---

## Important note about multi-platform builds

The script uses `docker build` with multiple `--platform` values and `--push`.

In many Docker setups, multi-platform builds are typically performed through Buildx. Whether plain `docker build` supports this on your machine depends on your Docker version and configuration.

If your environment does not support multi-platform build-and-push in this form, the likely failure point is the Docker build command rather than the script structure itself.

In other words:

- the script expresses the correct intent
- your Docker installation must support that intent

For students, the practical lesson is that image publishing workflows are partly a script concern and partly a builder/runtime capability concern.

---

### 7. Update `docker-compose.yml`

After each image is built and pushed, the script updates the corresponding image tag in Compose:

```bash
sed -i.bak "s|image: ${DOCKER_USER}/${NAME}:.*|image: ${FULL_IMAGE}|" "${COMPOSE_FILE}"
rm -f "${COMPOSE_FILE}.bak"
```

This means:

- the backend image line is rewritten to the new backend tag
- the frontend image line is rewritten to the new frontend tag

The temporary `.bak` file is created by `sed` and then removed immediately.

### Why this is useful

It keeps your deployment configuration aligned with the images you just published.

Without this step, you could successfully push:

```text
repping/zero-trust-backend:1.8.20
```

but still have Compose pointing at:

```text
repping/zero-trust-backend:1.8.19
```

which would create confusion and inconsistent environments.

---

## Script output

The script prints progress messages such as:

- connector reset
- which image is being built and pushed
- when `docker-compose.yml` is updated
- final version confirmation

Example shape:

```text
Resetting connector.js to 'wired' (static-config) for clean workshop start

Building and pushing repping/zero-trust-backend:1.8.20
Updating zero-trust-backend image tag in docker-compose.yml
Done repping/zero-trust-backend:1.8.20

Building and pushing repping/zero-trust-frontend:1.8.20
Updating zero-trust-frontend image tag in docker-compose.yml
Done repping/zero-trust-frontend:1.8.20

docker-compose.yml updated to version 1.8.20
```

This is not just cosmetic. It gives you checkpoints so you can see which stage failed if something goes wrong.

---

## What this script changes locally

After running the script successfully, your local repository will typically have at least these changes:

1. `backend/connector.js` reset to `wired`
2. `docker-compose.yml` updated to the new image tags

That means the script is not a pure build helper. It also mutates local working tree files.

This is usually the intended behavior, but it matters for Git hygiene.

If you run this script in a clean working tree and then inspect Git status, you may see modified files that should either be:

- committed intentionally
- reverted intentionally

depending on your workflow.

---

## Prerequisites

To run this script successfully, you generally need:

- Docker installed and running
- permission to build images
- permission to push to the target image repository
- a working `scripts/switch_connector.sh`
- a valid `docker-compose.yml` at the expected repo path

You also need the backend and frontend build contexts to be valid and complete.

---

## When to use this script

This script is useful when you want to:

- publish a new workshop image version
- keep backend and frontend tags synchronized
- update `docker-compose.yml` to the published release version
- standardize image publishing for repeated workshop releases

Typical cases:

- preparing a new workshop release
- publishing a tested set of backend/frontend changes
- cutting a new version after documentation or feature updates
- updating the image references used by the workshop stack

---

## When not to use this script

Do **not** use it when:

- you only want a local test build without pushing
- you want to preserve your current advanced connector in `backend/connector.js`
- you want to build only one image instead of both
- you do not want `docker-compose.yml` rewritten

In those cases, running Docker build commands manually is the more appropriate approach.

This script is for coordinated release-style publishing, not ad hoc local experimentation.

---

## Safety and operational considerations

### 1. Connector reset is deliberate

If you were working in:

- `dynamic`
- `jwt-roles`
- `jwt-ciba`
- `agent-dynamic`

those local connector changes will be overwritten when the script switches back to `wired`.

That is safe only if you expect it.

### 2. Compose file rewrite is global

The script updates image lines in `docker-compose.yml` in place.

That is convenient, but it means:

- you are changing deployment configuration
- the file now points to the newly published tag immediately

This is usually desirable for release workflows, but it is not something to overlook.

### 3. Push permissions matter

If you do not have permission to push under the chosen Docker namespace, the build step may succeed but the publish step will fail.

### 4. `--no-cache` makes builds slower

This improves freshness and repeatability but can significantly increase build time.

For release builds, that tradeoff is often acceptable.

---

## Relationship to other workshop scripts

### `switch_connector.sh`

`setup_images.sh` depends directly on it to reset the connector to `wired`.

### `purge_images.sh`

After repeated image publishing, local tags may accumulate. `purge_images.sh` is the natural follow-up script for cleaning old local image versions.

### `inspect_containers.sh`

After updating Compose to a new version and restarting the stack, `inspect_containers.sh` can help confirm the running containers are behaving normally.

---

## Troubleshooting

### The script fails immediately during connector reset

Check:

- `scripts/switch_connector.sh` exists and is executable
- the requested `wired` connector exists locally or remotely
- Docker is available if the switch script restarts the backend container

### Docker build fails

Possible causes:

- invalid Dockerfile
- missing files in build context
- unsupported multi-platform build setup
- Docker not running

### Docker push fails

Possible causes:

- not logged in to the registry
- no permission for the target namespace
- repository does not exist or is not writable
- network or registry outage

### `docker-compose.yml` was not updated correctly

The script relies on matching image lines using `sed`.

If the Compose file format changes substantially, the replacement expression may stop matching cleanly.

That is something to keep in mind if the Compose file is refactored later.

---

## Useful follow-up commands

Inspect the resulting image references:

```bash
grep '^    image:' docker-compose.yml
```

Check Git changes after running:

```bash
git status
git diff docker-compose.yml backend/connector.js
```

View local workshop images:

```bash
docker image ls | grep zero-trust
```

Clean up older local tags afterward:

```bash
./scripts/purge_images.sh
./scripts/purge_images.sh --apply
```

---

## Summary

`setup_images.sh` is a release-oriented build script for the workshop’s backend and frontend images. It:

- resets the backend connector to `wired`
- builds backend and frontend images
- pushes them under a chosen version tag
- updates `docker-compose.yml` to use those new tags

For students, it demonstrates how a workshop image release can be standardized. For engineers, it provides a compact image publishing workflow with synchronized Compose updates.
