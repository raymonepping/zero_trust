# purge_images.sh — Local Image Retention and Cleanup Script

**Location:** `scripts/purge_images.sh`

This script cleans up old local Docker image tags for the workshop’s custom application images. It keeps the newest N version tags for each target repository and, optionally, removes older tags to recover disk space.

It is intentionally conservative:

- it only targets two specific repositories
- it defaults to **dry run** mode
- it requires an explicit `--apply` flag before deleting anything

The intended audience is students and engineers who want a safe, repeatable way to manage local image buildup during frequent rebuilds and version iteration.

---

## What the script manages

The script targets these local image repositories:

- `repping/zero-trust-backend`
- `repping/zero-trust-frontend`

These are the workshop’s custom images that are rebuilt and retagged over time. As versions accumulate locally, Docker disk usage grows. This script helps keep only the most recent tags that are still useful for normal development and testing.

It does **not**:

- remove unrelated images from your machine
- delete containers
- delete volumes
- contact a remote registry
- change image tags in GitHub or Docker Hub

It works only on images already present on your local system.

---

## Why this script exists

During workshop development, custom images are rebuilt often:

- backend fixes
- frontend changes
- connector experiments
- versioned image pushes and local test runs

Each rebuild can leave older local tags behind. Over time that creates:

- wasted disk space
- cluttered `docker image ls` output
- confusion about which images are still current

This script keeps image retention simple:

```text
keep the newest N tags
remove the rest
```

That gives you a small rollback window without keeping an unlimited local image history.

---

## Usage

### Dry run

```bash
./scripts/purge_images.sh
```

This shows what would be kept and what would be removed, but deletes nothing.

### Actually remove old tags

```bash
./scripts/purge_images.sh --apply
```

### Keep a different number of recent tags

```bash
./scripts/purge_images.sh --keep 5
./scripts/purge_images.sh --keep 10 --apply
```

### Help

```bash
./scripts/purge_images.sh --help
```

---

## Default behavior

The script starts with:

```bash
KEEP_COUNT=3
APPLY=0
```

Meaning:

- keep the newest **3** tags per target repository
- do **not** delete anything unless `--apply` is given

This is a good default for a workshop because it preserves:

- the current image
- a couple of recent rollback points

without keeping a large amount of historical image data.

---

## How it works

The script is straightforward and uses only local Docker metadata.

### 1. Strict shell behavior

At the top:

```bash
set -euo pipefail
```

This makes failures surface immediately and prevents partial or misleading cleanup runs.

---

### 2. Argument parsing

The script supports three user-facing options:

- `--apply`
- `--keep N`
- `--help`

#### `--apply`

Without this flag, the script is a preview tool only.

When `--apply` is present:

```bash
APPLY=1
```

and old image tags are actually removed.

#### `--keep N`

This changes the retention count.

Validation rules:

- must be present
- must be numeric
- must be at least `1`

Invalid examples:

```bash
./scripts/purge_images.sh --keep 0
./scripts/purge_images.sh --keep abc
./scripts/purge_images.sh --keep
```

Each of those fails with an explicit error rather than continuing with ambiguous behavior.

#### `--help`

Prints usage information and exits.

---

### 3. Target repository list

The cleanup scope is defined explicitly:

```bash
TARGET_REPOS=(
  "repping/zero-trust-backend"
  "repping/zero-trust-frontend"
)
```

This is one of the most important safety features in the script.

Instead of pruning everything Docker considers unused, it limits itself to the workshop’s two custom repositories. That prevents accidental cleanup of unrelated local images you may need for other projects.

---

### 4. Dry-run announcement

When `--apply` is not supplied, the script prints:

```text
Dry run mode. No images will be deleted.
Use --apply to remove old tags.
```

This is useful because image deletion is destructive. The script makes the safety mode visible before any repository processing begins.

---

### 5. Collecting local tags

For each repository, the script runs:

```bash
docker image ls "$repo" --format '{{.Tag}}'
```

Then it filters and normalizes that output:

```bash
tr -d '\r'
awk 'NF && $0 != "<none>"'
sort -u -V
```

Breaking that down:

- `tr -d '\r'` removes carriage returns for shell portability
- `awk 'NF && $0 != "<none>"'` removes:
  - blank lines
  - dangling `<none>` tags
- `sort -u -V`:
  - removes duplicate tags
  - sorts them using **version-aware ordering**

That last step is important because plain lexical sorting would place:

```text
1.10.0
```

before:

```text
1.2.0
```

which is wrong for version tags.

Version sorting ensures the newest semantic-style tags naturally end up at the end of the list.

---

### 6. Deciding what to keep

After collecting tags, the script computes:

- total tag count
- which tags to keep
- which tags are old enough to remove

The logic is:

```text
if total <= KEEP_COUNT:
    remove nothing
else:
    keep the newest KEEP_COUNT tags
    remove everything older
```

Concretely:

```bash
keep_start=$(( total - KEEP_COUNT ))
keep_tags=( "${tags[@]:keep_start}" )
remove_tags=( "${tags[@]:0:keep_start}" )
```

This works because the tags were already sorted in ascending version order.

So if the sorted tag list is:

```text
1.8.10 1.8.11 1.8.12 1.8.13 1.8.14
```

and `KEEP_COUNT=3`, then:

- keep:
  - `1.8.12`
  - `1.8.13`
  - `1.8.14`
- remove:
  - `1.8.10`
  - `1.8.11`

---

### 7. Reporting what will happen

For each repository, the script prints:

- the repository name
- which tags will be kept
- which tags will be removed

This is true in both dry-run mode and apply mode.

That makes the output useful as:

- a preview
- a record of what was cleaned
- a quick check that version sorting behaved the way you expected

---

### 8. Deleting old tags

When `--apply` is enabled, the script removes each old tag individually:

```bash
docker image rm "${repo}:${tag}"
```

This is safer than broad pruning because:

- each deletion is explicit
- you can see exactly which image reference is being removed
- failures are tied to a specific tag

Because the script uses `set -e`, if Docker refuses to remove an image, the script stops immediately instead of silently continuing.

That is usually the right behavior for maintenance tooling.

---

## Example output

### Dry run

```text
Dry run mode. No images will be deleted.
Use --apply to remove old tags.

== repping/zero-trust-backend ==
Keeping newest 3 tag(s): 1.8.12 1.8.13 1.8.14
Removing 2 older tag(s): 1.8.10 1.8.11

== repping/zero-trust-frontend ==
Keeping newest 3 tag(s): 1.8.12 1.8.13 1.8.14
Removing 1 older tag(s): 1.8.11

Dry run complete.
```

### Apply mode

```text
== repping/zero-trust-backend ==
Keeping newest 3 tag(s): 1.8.12 1.8.13 1.8.14
Removing 2 older tag(s): 1.8.10 1.8.11
Removing repping/zero-trust-backend:1.8.10
Removing repping/zero-trust-backend:1.8.11

== repping/zero-trust-frontend ==
Keeping newest 3 tag(s): 1.8.12 1.8.13 1.8.14
Removing 1 older tag(s): 1.8.11
Removing repping/zero-trust-frontend:1.8.11

Purge complete.
```

---

## How Docker image deletion behaves

Removing an image tag does **not** always mean removing image data immediately.

Docker images are layer-based. Multiple tags can point to the same underlying image ID or share many layers.

That means:

- deleting one tag may free no space if another tag still references the same image
- deleting the last tag pointing to an image may free some space
- shared layers remain until no image references them

So the script should be thought of as:

```text
image tag retention management
```

not as a guaranteed one-to-one disk space reclamation tool.

If you want to see actual Docker storage impact afterward, use:

```bash
docker system df
```

or the workshop helper:

```bash
./scripts/inspect_containers.sh
```

---

## Safety considerations

This script is safer than `docker image prune -a`, but it is still destructive in apply mode.

Before using `--apply`, understand the following.

### 1. Running containers may still depend on a tag

If a container was started from a specific tag, Docker may refuse to remove that image while the container still exists.

That is generally a good thing. It prevents accidental deletion of images still in use.

### 2. Rollback history is reduced

If you keep only `3` tags, everything older disappears locally. That is fine for normal workshop iteration, but it reduces your immediate rollback options.

### 3. Version ordering assumes version-like tags

The script uses version-aware sorting. It works well for tags like:

```text
1.8.12
1.8.13
1.8.14
```

If you start using non-version tag names such as:

- `latest`
- `dev`
- `test-build`

the retention order may not match your mental model.

For this script, versioned tags are the safest convention.

---

## When to use this script

This script is useful when:

- you rebuild backend and frontend images frequently
- local Docker disk usage has grown
- `docker image ls` is cluttered with many old workshop tags
- you want a predictable retention policy instead of ad hoc cleanup

Typical times to run it:

- after a release cycle
- after a workshop day with many rebuilds
- before a demo, to keep the local environment tidy
- when Docker storage starts to feel bloated

---

## When not to use this script

Do **not** use it if:

- you intentionally need a long local rollback history
- you are not sure whether older image tags are still required for testing
- you are relying on unusual tag names rather than versioned tags
- you want to clean all Docker resources, not just workshop images

For broader cleanup, use Docker’s native tooling separately and more carefully.

---

## Comparison with Docker native prune commands

### `docker image prune`

Removes dangling images only.

Good for:

- cleaning anonymous leftovers

Not enough for:

- managing a versioned tag retention policy

### `docker image prune -a`

Removes all unused images.

Good for:

- aggressive space recovery

Risk:

- broader blast radius
- affects unrelated projects too

### `scripts/purge_images.sh`

Removes only old tags from the two workshop repositories.

Good for:

- predictable local retention
- low-risk cleanup
- repeated workshop use

This script fills a different niche than Docker’s generic prune commands.

---

## Troubleshooting

### “No local tags found.”

This means Docker has no local tags for that repository.

Possible reasons:

- the images were never built locally
- they were already removed
- you are using a different repository name than the script expects

Check with:

```bash
docker image ls | grep zero-trust
```

### “Found N tag(s). Nothing to remove.”

This means the total number of tags is already less than or equal to the retention count.

No action is needed.

### Docker refuses to remove an image

A common reason is that a container still references that image.

Check:

```bash
docker ps -a
```

and inspect whether an existing container is tied to that image tag or image ID.

### The “newest” tags are not what I expected

That usually means your tag names are not strictly version-like.

The script is built for version tags, not arbitrary labels.

---

## Useful follow-up commands

List local workshop images:

```bash
docker image ls repping/zero-trust-backend
docker image ls repping/zero-trust-frontend
```

Preview cleanup:

```bash
./scripts/purge_images.sh
```

Apply cleanup:

```bash
./scripts/purge_images.sh --apply
```

Keep more history:

```bash
./scripts/purge_images.sh --keep 5 --apply
```

Check resulting Docker storage:

```bash
docker system df
```

---

## Summary

`purge_images.sh` is a focused local maintenance script for the workshop’s backend and frontend images. It:

- keeps the newest N version tags
- removes older local tags only when `--apply` is provided
- defaults to dry-run mode
- limits its scope to the workshop’s two image repositories
- helps control disk growth without broad Docker cleanup

For students, it demonstrates safe retention-based cleanup. For engineers, it provides a predictable low-blast-radius alternative to broader Docker prune commands.
