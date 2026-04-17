# Workshop Container Versioning

This document describes how to use the workshop version checking script:

- `./scripts/check_versions.sh`

It compares the currently pinned workshop container images against the latest matching tags published in Docker Hub or Quay.

It supports:

- full table output
- filtering by logical type
- sorting by image or status
- upgrades-only output
- JSON output
- no-color output
- timeout and retry tuning for registry calls
- digest awareness in JSON output

---

## Script Location

```bash
./scripts/check_versions.sh
```

---

## What the Script Checks

The script includes images defined in:

- `docker-compose.yml`
- local Dockerfiles, including:
  - `./db/Dockerfile`
  - `./ollama/Dockerfile`

Tracked areas currently include:

- workshop application images
- HashiCorp images
- PostgreSQL images
- identity images
- LLM image
- web image
- Linux base image
- storage image

**Note on floating tags:** images pinned to floating tags such as `latest` or `alpine` (minio, boundary-target, ollama) will always show an upgrade in the output, because the script compares the floating tag against the latest concrete release tag. This is expected behavior.

**Note on `ubuntu-sshd`:** the `rastasheep/ubuntu-sshd` image is unmaintained and has no new releases to track. The script tracks the upstream `ubuntu` image tags instead, so the `ubuntu-sshd` row reflects how far the base OS has drifted rather than a registry release comparison.

---

## Basic Usage

Run the full report:

```bash
./scripts/check_versions.sh
```

Sort explicitly by image:

```bash
./scripts/check_versions.sh --sort image
```

Show only upgrades:

```bash
./scripts/check_versions.sh --only-upgrades
```

Disable color:

```bash
./scripts/check_versions.sh --no-color
```

Return JSON:

```bash
./scripts/check_versions.sh --json
```

---

## Type Filtering

Use `--type` to limit output to a logical image group.

### Supported Types

- `all`
- `workshop`
- `storage`
- `hashicorp`
- `database`
- `identity`
- `llm`
- `web`
- `linux`

### Examples

Workshop application images only:

```bash
./scripts/check_versions.sh --type workshop
```

HashiCorp-related images only:

```bash
./scripts/check_versions.sh --type hashicorp
```

Database-related images only:

```bash
./scripts/check_versions.sh --type database
```

Identity services only:

```bash
./scripts/check_versions.sh --type identity
```

LLM only:

```bash
./scripts/check_versions.sh --type llm
```

Web target only:

```bash
./scripts/check_versions.sh --type web
```

Linux base image only:

```bash
./scripts/check_versions.sh --type linux
```

All tracked images explicitly:

```bash
./scripts/check_versions.sh --type all
```

---

## Sorting

The script supports two sort modes.

### Sort by Image

Alphabetical order by image label:

```bash
./scripts/check_versions.sh --sort image
```

### Sort by Status

Upgrades first, then unknown, then current:

```bash
./scripts/check_versions.sh --sort status
```

---

## JSON Output

JSON output is useful for automation, CI pipelines, or post-processing with `jq`.

Example:

```bash
./scripts/check_versions.sh --json
```

Filter to HashiCorp only:

```bash
./scripts/check_versions.sh --type hashicorp --json
```

Show only upgrade rows in JSON:

```bash
./scripts/check_versions.sh --json --only-upgrades
```

### JSON Fields

Each result row includes:

- `label`
- `display`
- `type`
- `image`
- `current`
- `latest`
- `status`
- `registry`
- `latest_digest`

The top-level JSON also includes:

- `selected_type`
- `sort_by`
- `only_upgrades`
- `timeout`
- `retries`
- `upgrades_available`
- `results`

---

## Timeouts and Retries

Registry lookups can be tuned if the network is slow or the registry is rate-limiting.

Example:

```bash
./scripts/check_versions.sh --timeout 20 --retries 3
```

---

## Caching

Registry lookups are cached locally so repeated runs return results immediately.

### How it works

- On the first run each unique registry/image/filter combination is fetched from the registry and stored in a local JSON file.
- On subsequent runs within the TTL window the cached result is used instead of making an HTTP call.
- The cache naturally deduplicates redundant fetches — for example `vault` and `vault-agent` share the same registry image, so only one API call is made for both rows.

### Cache location

```text
${XDG_CACHE_HOME:-~/.cache}/zero_trust/check_versions.json
```

### Default TTL

3600 seconds (1 hour).

### Cache options

| Option              | Description                                                    |
| ------------------- | -------------------------------------------------------------- |
| `--no-cache`        | Skip the cache entirely — always fetch fresh from the registry |
| `--cache-ttl SEC`   | Override the TTL for this run                                  |
| `--cache-clear`     | Delete the cache file and exit                                 |

### Examples

Force a fresh fetch (bypass cache):

```bash
./scripts/check_versions.sh --no-cache
```

Use a shorter TTL of 5 minutes:

```bash
./scripts/check_versions.sh --cache-ttl 300
```

Clear the cache:

```bash
./scripts/check_versions.sh --cache-clear
```

### Cache status in output

When the table output is used, a cache summary line is shown at the bottom:

```
Cache: 11 hit(s), 5 fetch(es) — TTL 3600s — /Users/you/.cache/zero_trust/check_versions.json
```

In JSON output, the top-level `cache` object contains:

- `enabled` — whether caching was active
- `ttl` — TTL used for this run
- `hits` — number of entries served from cache
- `misses` — number of entries fetched from the registry
- `file` — absolute path to the cache file

---

## Example Reference Output

Reference command:

```bash
./scripts/check_versions.sh --sort image
```

Reference output (illustrative — version numbers are examples, not the current state):

```text
╔══════════════════════════════════════════════════════════════════════╗
║         Zero Trust Workshop — Container Version Check                ║
╚══════════════════════════════════════════════════════════════════════╝

IMAGE                                   CURRENT           LATEST            STATUS
──────────────────────────────────────────────────────────────────────────────
backend (repping/zero-trust-backend)    1.8.18            1.8.18            ✓
boundary-controller (hashicorp/bounda   0.21.2-ent        0.21.2-ent        ✓
boundary-db (postgres)                  16                18.3              ↑
boundary-egress-worker (hashicorp/bou   0.21.2-ent        0.21.2-ent        ✓
boundary-ingress-worker (hashicorp/bo   0.21.2-ent        0.21.2-ent        ✓
boundary-target (nginx)                 alpine            1.30.0-alpine     ↑
database (postgres)                     17.4              18.3              ↑
frontend (repping/zero-trust-frontend   1.8.18            1.8.18            ✓
keycloak (quay.io/keycloak/keycloak)    26.5.7            26.6.1            ↑
ldap-admin (osixia/phpldapadmin)        0.9.0             0.9.0             ✓
minio (minio/minio)                     latest            RELEASE.2025-09-07T16-13-09Z-cpuv1  ↑
ollama (ollama/ollama)                  latest            0.21.0            ↑
openldap (osixia/openldap)              1.5.0             1.5.0             ✓
ubuntu-sshd (ubuntu)                    18.04             26.04             ↑
vault (hashicorp/vault-enterprise)      1.21.4-ent        2.0.0-ent         ↑
vault-agent (hashicorp/vault-enterpri   1.21.4-ent        2.0.0-ent         ↑

9 upgrade(s) available.
```

---

## Useful Commands

Show only upgrades, sorted by image:

```bash
./scripts/check_versions.sh --sort image --only-upgrades
```

Show only upgrades, sorted by status:

```bash
./scripts/check_versions.sh --sort status --only-upgrades
```

HashiCorp upgrades only in JSON:

```bash
./scripts/check_versions.sh --type hashicorp --json --only-upgrades
```

All tracked images in JSON, no ANSI colors needed for logs:

```bash
./scripts/check_versions.sh --type all --json --no-color
```

---

## Notes

- Official Docker Hub library images such as `postgres`, `nginx`, and `ubuntu` are resolved through the `library/...` namespace.
- Floating tags such as `latest` and `alpine` are compared against the latest matching concrete release where possible.
- Digest information is included in JSON output when the registry API provides it.
- Output is intended for workshop maintenance, image review, and upgrade planning.
- Requires `curl` ≥ 7.71 (for `--retry-all-errors`) and `jq`.

---

## See Also

- [README.md](../README.md) — Workshop overview, startup flow, and lab progression
- [docs/architecture.md](./architecture.md) — Full architectural reference including service roles
- [docs/readme_verify_stack.md](./readme_verify_stack.md) — Preflight environment verification
- [docs/readme_verify_environment.md](./readme_verify_environment.md) — Full environment verification wrapper
