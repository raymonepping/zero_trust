# inspect_containers.sh — Container Resource Inspection Script

**Location:** `scripts/inspect_containers.sh`

This script prints a compact, human-readable snapshot of Docker container resource usage for the workshop stack. It is designed for fast operational visibility: which containers are running, how much CPU and memory they are using, and how much network and disk I/O they have generated.

It also prints a second table summarizing overall Docker disk usage, so you can quickly see whether images, containers, volumes, or build cache are consuming too much space.

The intended audience is students and engineers who want to understand container behavior without opening Docker Desktop or manually stitching together multiple `docker` commands.

---

## What the script shows

The script produces two sections:

1. **Container Resource Usage**
2. **Disk Usage**

### Container Resource Usage

This section is built from:

```bash
docker stats --no-stream
```

The script reformats that output into aligned columns and adds a colorized CPU bar for easier scanning.

### Disk Usage

This section is built from:

```bash
docker system df
```

It summarizes how much Docker storage is currently consumed by images, containers, local volumes, and build cache.

---

## Usage

Run it from the repository root:

```bash
./scripts/inspect_containers.sh
```

Because the script uses the Docker CLI directly, it does not need any special workshop-specific environment variables.

---

## Prerequisites

The script assumes:

- Docker is installed and running
- Your shell user can access the Docker daemon
- At least some containers are running if you want meaningful container stats

If Docker is unavailable, or your user cannot access the Docker socket, the script will fail before it can print useful results.

---

## How it works

The script is intentionally simple and reads only live Docker metadata. It does not inspect application logs, container internals, or any secret material.

### 1. Strict shell behavior

At the top of the script:

```bash
set -euo pipefail
```

This makes failures visible immediately:

- `-e` stops on command errors
- `-u` fails on unset variables
- `pipefail` makes pipeline failures propagate correctly

That is useful for an operational script because silent failures would make the output misleading.

### 2. Color and formatting setup

The script defines ANSI color codes for headings and the CPU usage bar:

- green for low CPU usage
- yellow for moderate CPU usage
- orange for high CPU usage
- red for very high CPU usage

These colors are used only for display. They do not affect the underlying metrics.

### 3. Resolving container names

Before collecting stats, the script builds a mapping of:

```text
container ID -> container name
```

using:

```bash
docker ps --format "{{.ID}}|{{.Names}}"
```

This lets it normalize container names consistently, even if Docker reports slightly different name forms in different commands.

### 4. CPU bar rendering

The `bar()` helper converts a CPU percentage into a 20-character visual bar:

- `0%` means an empty bar
- `100%` means one full CPU core saturated
- values above `100%` are possible when a container uses multiple cores

The bar is color-coded by utilization:

- `< 25%` green
- `25–49%` yellow
- `50–74%` orange
- `75%+` red

This makes spikes easy to spot visually even before reading the exact numbers.

### 5. Fixed-width tabular output

The script defines explicit column widths so the output stays aligned:

- container name
- CPU bar and CPU value
- memory percentage
- network I/O
- block I/O

That matters because the default `docker stats` output can become hard to compare when container names or metric strings have different lengths.

### 6. Alphabetical ordering

The script trims the workshop-specific container prefix from names:

```text
zero_trust_backend -> backend
zero_trust_keycloak -> keycloak
```

It then sorts the rows alphabetically by the displayed name before printing them.

This is useful because:

- the output order is stable between runs
- it is easier to compare services quickly
- students can find a specific container without guessing Docker’s native ordering

### 7. Disk usage summary

The second half of the script calls:

```bash
docker system df --format "{{.Type}}|{{.TotalCount}}|{{.Active}}|{{.Size}}|{{.Reclaimable}}"
```

and formats the result into a second table.

This tells you:

- how many objects of each type exist
- how many are currently active
- total space consumed
- how much space could potentially be reclaimed

---

## Understanding the output

### Section 1: Container Resource Usage

Example shape:

```text
NAME         │ CPU                                         │     MEM% │ NET-I/O              │ BLOCK-I/O
backend      │ ███░░░░░░░░░░░░░░░ 0.32 cores (32.00%)      │    4.21% │ 12.3MB / 8.1MB      │ 3.2MB / 0B
db           │ ██░░░░░░░░░░░░░░░░ 0.18 cores (18.00%)      │    2.76% │ 1.1MB / 980kB       │ 8.5MB / 1.2MB
frontend     │ ░░░░░░░░░░░░░░░░░░ 0.01 cores (1.00%)       │    1.05% │ 500kB / 420kB       │ 0B / 0B
```

#### NAME

The script strips the `zero_trust_` prefix so you see short names such as:

- `backend`
- `db`
- `frontend`
- `keycloak`
- `vault`

#### CPU

The CPU column contains two pieces of information:

1. A bar
2. A numeric display such as:

```text
0.32 cores (32.00%)
```

Important detail: Docker CPU percentages are not capped at `100%`.

Examples:

- `50%` means roughly half a CPU core
- `100%` means one full core
- `250%` means about two and a half cores

For this reason, the script also converts the percentage into “cores” to make the number easier to interpret.

#### MEM%

This is the percentage of host memory currently used by the container.

High memory usage can indicate:

- a legitimate workload
- a memory leak
- a service that needs a limit or tuning

On its own, this number does not mean something is wrong. It is most useful when you compare it over time.

#### NET-I/O

This is cumulative network traffic since the container started:

```text
received / transmitted
```

Use it to spot:

- a chatty service
- a container that is unexpectedly talking a lot
- services that appear idle when they should be active

#### BLOCK-I/O

This is cumulative filesystem read/write activity reported by Docker.

It can help identify:

- a database writing heavily to disk
- a container repeatedly reading large files
- noisy local build or cache behavior

---

## Interpreting the CPU bar correctly

The CPU bar is a convenience indicator, not a performance conclusion.

A red bar does **not** automatically mean the container is unhealthy. It only means the container is consuming significant CPU at the moment the sample was taken.

Good uses:

- identify which service deserves deeper investigation
- compare containers quickly
- observe whether a restart or workload change reduced pressure

Poor uses:

- concluding a service is broken from one snapshot alone
- assuming low CPU means healthy and high CPU means unhealthy

Always interpret CPU together with:

- logs
- response times
- application behavior
- workload context

---

## Understanding the Disk Usage table

Example shape:

```text
TYPE             │ TOTAL   │ ACTIVE  │ SIZE         │ RECLAIMABLE
Images           │ 8       │ 6       │ 3.1GB        │ 850MB (27%)
Containers       │ 6       │ 6       │ 120MB        │ 0B (0%)
Local Volumes    │ 5       │ 5       │ 2.4GB        │ 0B (0%)
Build Cache      │ 12      │ 0       │ 640MB        │ 640MB (100%)
```

### TYPE

Docker object category:

- images
- containers
- local volumes
- build cache

### TOTAL

How many objects of that type exist on the machine.

### ACTIVE

How many are currently in use by running containers or current references.

### SIZE

Total disk space consumed by that category.

### RECLAIMABLE

How much space Docker believes could be freed.

This is useful for deciding whether it is worth running cleanup commands such as:

```bash
docker system prune
docker image prune
docker builder prune
```

Use cleanup carefully. Some of those commands remove cached layers and stopped containers that you may still want.

---

## When this script is useful in the workshop

This script is especially useful when students are:

- starting the full stack for the first time
- switching connector modes and checking which services wake up
- debugging whether `ollama`, `vault`, `keycloak`, or `db` is the noisy component
- verifying that resource usage looks reasonable after a demo
- checking whether Docker disk usage is growing because of repeated rebuilds

It is also useful before asking for help, because it gives a quick machine-level snapshot of the stack.

---

## What this script does not do

This script is intentionally shallow. It does **not**:

- show application logs
- inspect health check status directly
- tell you why a container is using resources
- distinguish healthy load from unhealthy load
- read secret values, environment variables, or mounted file contents

If you need those answers, use this script as the starting point, then move to:

- `docker compose ps`
- `docker logs <container>`
- workshop-specific helper scripts
- backend or Vault diagnostics

---

## Debug mode

The script supports a simple debug mode:

```bash
DEBUG_INSPECT_CONTAINERS=1 ./scripts/inspect_containers.sh
```

When enabled, it prints the normalized container names to standard error while preserving the main formatted output on standard output.

This is mainly useful if you are modifying the script and want to verify how container names are being trimmed and displayed.

---

## Troubleshooting

### “permission denied while trying to connect to the Docker daemon socket”

Your shell user cannot access Docker.

Check:

- Docker Desktop or Docker Engine is running
- your user has permission to access Docker
- you are using the correct Docker context

### No containers appear in the resource table

Possible causes:

- the workshop stack is not running
- Docker is running but there are no active containers
- you are connected to a different Docker context than expected

Start or verify the stack with:

```bash
docker compose ps
```

### Values look stale or confusing

Remember that:

- `docker stats --no-stream` is a one-time snapshot
- `NET-I/O` and `BLOCK-I/O` are cumulative, not instantaneous
- short-lived spikes may be missed if they happened between samples

Run the script multiple times if you want to compare behavior before and after an action.

---

## Why this script is useful for students

Students often struggle to connect application behavior to infrastructure behavior. This script helps bridge that gap:

- it shows that a “simple app” is really a collection of services
- it makes resource consumption visible without extra tooling
- it teaches how to reason about container-level symptoms before debugging application code

For workshop teaching, that is valuable because it creates a habit of observing the system before making changes.

---

## Summary

`inspect_containers.sh` is a lightweight operational dashboard for the workshop stack. It:

- lists running containers in alphabetical order
- shows CPU, memory, network, and block I/O in a readable table
- visualizes CPU pressure with a colorized bar
- summarizes Docker disk usage in a second table
- avoids exposing secret values or internal application data

Use it when you want a quick, low-friction view of how the local stack is behaving.
