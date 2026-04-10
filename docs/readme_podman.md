# Podman Environment Prerequisites

**Stack definition:** `docker-compose.yml`

This document explains what a machine needs in order to run the Zero Trust Workshop with Podman. It is written for students using Podman Desktop or `podman machine`, and for engineers validating a Podman-based environment.

The workshop was originally authored around Docker Compose semantics, so the Podman guidance here is practical rather than ideological:

- what must be installed
- how to size the Podman machine
- what Podman features this stack depends on
- which commands are useful during operation

No sensitive values are included here.

---

## Table Of Contents

- [Purpose](#purpose)
- [What This Stack Needs From Podman](#what-this-stack-needs-from-podman)
- [Required Software](#required-software)
- [Recommended Podman Machine Sizing](#recommended-podman-machine-sizing)
- [Why 8 GB Is A Better Fit Here](#why-8-gb-is-a-better-fit-here)
- [Ports And Network Requirements](#ports-and-network-requirements)
- [Storage Requirements](#storage-requirements)
- [Required Local Files And Directories](#required-local-files-and-directories)
- [Recommended Podman Workflow](#recommended-podman-workflow)
- [Useful Podman And Compose Commands](#useful-podman-and-compose-commands)
- [Resource Usage Overview](#resource-usage-overview)
- [Compatibility Notes](#compatibility-notes)
- [Troubleshooting The Setup](#troubleshooting-the-setup)
- [Troubleshooting](#troubleshooting)

---

## Purpose

This workshop uses:

- published container images
- local image builds
- bind mounts
- named volumes
- bridge networking
- health checks
- capability flags such as `IPC_LOCK`
- host port publishing

Podman can run this stack, but the machine backing Podman must be sized appropriately and the Compose implementation must support the Compose features used by the repository.

---

## What This Stack Needs From Podman

From `docker-compose.yml`, the stack expects:

- local builds from `./db` and `./ollama`
- pulls of published frontend and backend images
- bind mounts for `./backend` and `./frontend`
- bind mounts for Vault config and audit paths
- named volumes for persistent data
- published ports for app access
- multiple internal bridge networks
- `cap_add: IPC_LOCK` for Vault and Vault Agent

The active services are:

- PostgreSQL
- Vault
- Vault Agent
- Ollama
- backend
- frontend
- OpenLDAP
- LDAP Admin
- Keycloak

That means Podman is not just running one container. It is running a full multi-service lab environment.

---

## Required Software

Recommended prerequisites:

- Podman
- Podman Compose support

Depending on your environment, that usually means one of:

- `podman compose`
- `podman-compose`

Recommended checks:

```bash
podman version
podman machine list
podman compose version
```

If `podman compose` is unavailable in your environment, check whether `podman-compose` is installed instead.

---

## Recommended Podman Machine Sizing

Your current machine init is:

```bash
podman machine init \
  --cpus 8 \
  --memory 12288 \
  --disk-size 120
```

For this workshop, a more balanced default is:

```bash
podman machine init \
  --cpus 8 \
  --memory 8192 \
  --disk-size 120
```

Recommended target:

- **CPU:** 8 vCPU
- **Memory:** 8192 MB
- **Disk:** 120 GB

If the machine already exists, recreate or reconfigure it according to your Podman platform’s supported workflow.

---

## Why 8 GB Is A Better Fit Here

Based on the Compose stack:

- `ollama` declares a memory limit of `4G`
- `ollama` declares a CPU limit of `3.0`
- the rest of the stack includes database, identity, Vault, UI, and API services

Your observation that the current machine is only using about 51% of 12 GB is consistent with the stack profile. For the workshop:

- **12 GB is comfortable but not necessary**
- **8 GB is a more efficient baseline**

Why keep CPU at 8:

- Ollama benefits from CPU headroom
- Keycloak startup is smoother
- backend/frontend hot reload remains responsive

Why keep disk at 120 GB:

- model downloads can be large
- named volumes accumulate state
- image rebuilds and cached layers add up over time

You could run with less disk, but 120 GB avoids a common class of workshop failures caused by model and image churn.

---

## Ports And Network Requirements

The stack publishes these host ports:

| Port | Service | Notes |
| ---- | ------- | ----- |
| `3000` | backend | main API |
| `5432` | db | PostgreSQL |
| `8081` | ldap-admin | phpLDAPadmin |
| `8082` | keycloak | Keycloak web UI |
| `8088` | frontend | Vite UI default host port |
| `8200` | vault | Vault HTTP API |
| `11434` | ollama | Ollama API |
| `1389` | openldap | LDAP |
| `1636` | openldap | LDAPS |

These ports must be free on the host side of the Podman machine mapping.

The stack also defines four networks:

- `net-frontend`
- `net-backend`
- `net-data`
- `net-egress`

Three of them are marked internal. That isolation is part of the workshop design and should be preserved.

---

## Storage Requirements

Persistent storage is needed for:

- PostgreSQL data
- Vault data
- Vault Agent rendered credentials
- LDAP data and config
- Keycloak data
- Ollama models
- locally cached images and build layers

### Recommended disk guidance

- **Machine disk:** 120 GB is a good operational target
- **Practical free-space expectation:** at least 40 GB genuinely free before you start

Ollama models and build layers are the main reasons not to undersize the machine disk.

Useful inspection commands:

```bash
podman system df
podman volume ls
podman images
```

---

## Required Local Files And Directories

From the Compose file, Podman must be able to mount these repo paths:

- `./backend`
- `./frontend`
- `./db`
- `./ollama`
- `./vault/config.hcl`
- `./vault/config/vault.hclic`
- `./vault/audit`
- `./vault-agent/config`
- `.env`

Important note for Podman:

- the Compose file already uses `:Z` on the Vault config mounts
- that is relevant for SELinux-aware environments

The stack also uses bind mounts for live source editing:

- `./backend:/app`
- `./frontend:/app`

That is essential to the workshop workflow.

---

## Recommended Podman Workflow

### 1. Create the machine

Recommended init:

```bash
podman machine init \
  --cpus 8 \
  --memory 8192 \
  --disk-size 120
```

### 2. Start the machine

```bash
podman machine start
```

### 3. Validate runtime and compose support

```bash
podman version
podman machine list
podman compose version
```

### 4. Start foundation services

```bash
podman compose up -d db openldap ldap-admin keycloak
```

### 5. Run repository setup scripts from the host

Follow the workshop setup docs for database seeding and identity setup.

### 6. Start backend and frontend

```bash
podman compose up -d backend frontend
```

### 7. Add Vault services when progressing the labs

```bash
podman compose up -d vault vault-agent
```

### 8. Start the full stack when needed

```bash
podman compose up -d
```

---

## Useful Podman And Compose Commands

### Machine lifecycle

```bash
podman machine list
podman machine start
podman machine stop
podman machine ssh
```

### Stack lifecycle

```bash
podman compose up -d
podman compose down
podman compose stop
podman compose start
podman compose restart
```

### Targeted service control

```bash
podman compose up -d backend frontend
podman compose restart backend
podman compose restart frontend
podman compose logs -f backend
podman compose logs -f keycloak
```

### Inspection

```bash
podman ps
podman stats --no-stream
podman system df
podman network ls
podman volume ls
podman images
```

### Exec and logs

```bash
podman exec -it zero_trust_backend sh
podman exec -it zero_trust_db sh
podman exec -it zero_trust_vault sh
podman logs zero_trust_backend
podman logs zero_trust_keycloak
```

### Build and refresh

```bash
podman compose build
podman compose build db ollama
podman compose up -d --build
```

### Cleanup

```bash
podman compose down -v
podman image prune
podman volume prune
podman system prune
```

Use cleanup carefully. Named volumes contain workshop state.

---

## Resource Usage Overview

The quickest way to inspect live resource usage for this workshop is:

```bash
./scripts/inspect_containers.sh
```

That script summarizes:

- container CPU usage
- container memory usage
- network I/O
- block I/O
- image size
- container writable layer size
- named volume size

Example output from a healthy running workshop environment:

```text
=== Container Resource Usage ===
NAME         │ CPU                                         │     MEM% │ NET-I/O              │ BLOCK-I/O
───────────────────────────────────────────────────────────────────────────────────────────────────────────────────
backend      │ ███░░░░░░░░░░░░░░░░░ 0.18 cores (18.14%)    │    0.64% │ 16.6MB / 10.9MB      │ 0B / 4.1kB
db           │ ██░░░░░░░░░░░░░░░░░░ 0.14 cores (14.35%)    │    0.69% │ 1.6MB / 1.31MB       │ 64.4MB / 26.5MB
frontend     │ █░░░░░░░░░░░░░░░░░░░ 0.07 cores (7.35%)     │    0.73% │ 7.42MB / 10.3MB      │ 0B / 12.3kB
keycloak     │ ██░░░░░░░░░░░░░░░░░░ 0.10 cores (10.19%)    │    5.66% │ 360kB / 218kB        │ 220MB / 17.3MB
ollama       │ ███████░░░░░░░░░░░░░ 0.37 cores (36.87%)    │    4.46% │ 315kB / 81.6kB       │ 2.14GB / 0B
openldap     │ ░░░░░░░░░░░░░░░░░░░░ 0.05 cores (4.69%)     │    0.34% │ 309kB / 25.7kB       │ 35.1MB / 190kB
vault        │ ███████████████████░ 0.96 cores (96.03%)    │    4.20% │ 4.54MB / 8.02MB      │ 361MB / 7.18GB
vault_agent  │ ░░░░░░░░░░░░░░░░░░░░ 0.03 cores (3.15%)     │    0.20% │ 77.7kB / 50.8kB      │ 0B / 118kB

=== Disk Usage (zero_trust project) ===

Images
────────────────────────────────────────────────────────────────────────
IMAGE                                                    SIZE STATUS
────────────────────────────────────────────────────────────────────────
hashicorp/vault-enterprise:1.21.4-ent                 506.3MB
osixia/openldap:1.5.0                                 250.8MB
osixia/phpldapadmin:0.9.0                             290.1MB
quay.io/keycloak/keycloak:26.5.7                      446.3MB
repping/zero-trust-backend:1.8.16                     180.1MB
repping/zero-trust-frontend:1.8.16                    221.6MB
zero_trust-db:latest                                  445.3MB
zero_trust-ollama:latest                                5.2GB
────────────────────────────────────────────────────────────────────────
TOTAL                                                   7.5GB

Containers
────────────────────────────────────────────────────────────────────────
NAME                                STATUS             SIZE IMAGE
────────────────────────────────────────────────────────────────────────
backend                             Up 12 hours      31.4kB repping/zero-trust-backend:1.8.16
db                                  Up 18 hours       1.1MB zero_trust-db:latest
frontend                            Up 13 hours      2.19MB repping/zero-trust-frontend:1.8.16
keycloak                            Up 18 hours       167MB quay.io/keycloak/keycloak:26.5.7
ldap-admin                          Exited            161kB osixia/phpldapadmin:0.9.0
ollama                              Up 18 hours      2.29GB zero_trust-ollama:latest
openldap                            Up 18 hours       258kB osixia/openldap:1.5.0
vault_agent                         Up 12 hours       100kB hashicorp/vault-enterprise:1.21.4-ent
vault                               Up 18 hours       518MB hashicorp/vault-enterprise:1.21.4-ent

Volumes
────────────────────────────────────────────────────────────────────────
VOLUME                                         SIZE STATUS
────────────────────────────────────────────────────────────────────────
db_data                                      63.3MB
keycloak_data                                 1.5MB
ollama_data                                     1KB
openldap-config                                83KB
openldap-data                                 144KB
vault-agent-secrets                             0KB
vault_data                                   64.1MB
────────────────────────────────────────────────────────────────────────
TOTAL                                       129.2MB
```

How to read this:

- `ollama` is the largest image and one of the main runtime resource consumers
- `vault` can show high block I/O during active workshop operations
- `keycloak` is usually one of the heavier memory consumers after Ollama
- backend and frontend remain relatively light
- the named volumes are small compared to image size and Ollama/container layers

This example is not a hard requirement, but it is a useful reference point for a healthy local stack.

---

## Compatibility Notes

### 1. Compose implementation matters

Not every Podman Compose path behaves identically to Docker Compose.

Pay attention to support for:

- healthcheck-based `depends_on`
- bind mount labeling
- named volumes
- published ports
- internal bridge networks

If your Podman environment behaves strangely, the first question should be whether the Compose implementation supports the features used by this stack cleanly.

### 2. `IPC_LOCK` support is required

Vault and Vault Agent both request:

```yaml
cap_add:
  - IPC_LOCK
```

If your Podman environment strips or mishandles that capability, Vault behavior may degrade.

### 3. Bind-mounted development flow is intentional

The backend and frontend containers are expected to read live source from the host checkout. If your Podman machine cannot see or mount the repo correctly, the workshop experience will be poor.

### 4. Ollama remains the largest resource consumer

If you need to optimize the stack under Podman, start with Ollama:

- memory
- CPU
- model downloads

---

## Troubleshooting The Setup

If Podman networking, port forwarding, or Compose state becomes inconsistent, the most reliable recovery path is:

1. stop and remove the Podman machine
2. recreate it with known-good sizing
3. start clean
4. tear down any stale compose state
5. prune unused Podman networks
6. bring up a small subset first
7. verify published ports and in-VM listeners

Important warning:

- `podman machine rm -f` is destructive for that machine
- machine-local images, volumes, and networks are lost unless separately preserved

### Recommended machine reset sequence

```bash
podman machine stop
podman machine rm -f

podman machine init \
  --cpus 8 \
  --memory 8192 \
  --disk-size 120

podman machine start
```

### Validate the machine and runtime

```bash
podman machine list
podman info
podman ps
```

### Reset stale Compose networking

```bash
podman compose down
podman network prune -f
```

Then bring up a small target first:

```bash
podman compose up -d vault
```

You can then verify published ports from the host:

```bash
podman ps --format "table {{.Names}}\t{{.Ports}}"
```

For this workshop, a healthy result should show port mappings such as:

- `zero_trust_vault` -> `8200`
- `zero_trust_db` -> `5432`
- `zero_trust_openldap` -> `1389`, `1636`
- `zero_trust_ldap-admin` -> `8081`
- `zero_trust_keycloak` -> `8082`
- `zero_trust_frontend` -> `8088`
- `zero_trust_backend` -> `3000`
- `zero_trust_ollama` -> `11434`

`zero_trust_vault_agent` typically has no published host port, which is expected.

### Inspect networking inside the Podman machine

Open a shell into the machine:

```bash
podman machine ssh
```

Then inspect listeners, interfaces, and Podman networks:

```bash
ss -tulnp
ip addr
podman network ls
```

What you want to see:

- `rootlessport` listeners on the expected published ports
- the Podman machine interface with a valid address
- workshop networks such as:
  - `zero_trust_net-frontend`
  - `zero_trust_net-backend`
  - `zero_trust_net-data`
  - `zero_trust_net-egress`

### Verify a real service from the host

For Vault, a good end-to-end connectivity check is:

```bash
curl -s http://localhost:8200/v1/sys/health | jq
```

You are looking for:

- `initialized: true`
- `sealed: false`
- `standby: false`

That confirms:

- port forwarding from host to machine is working
- the Vault container is reachable
- the service itself is healthy enough to answer the health endpoint

### Why this sequence works

This sequence addresses the most common Podman failure modes in workshop setups:

- stale machine networking
- stale compose-created bridge networks
- broken host-to-machine port forwarding
- confusion between host and machine-side listener state

It is a blunt recovery method, but it is effective.

### Sanity check with a simple NGINX container

If you are not sure whether the workshop is broken or Podman itself is broken, test the runtime with a trivial web server first.

Run:

```bash
podman rm -f podman-connectivity-test 2>/dev/null || true
podman run -d --name podman-connectivity-test -p 8089:80 docker.io/library/nginx:alpine
curl -I http://localhost:8089
podman ps --format "table {{.Names}}\t{{.Ports}}"
```

What you want to see:

- the container is running
- port `8089` is published
- `curl` returns an HTTP response such as `200 OK`

If this fails, the problem is below the workshop stack. Look first at:

- Podman machine health
- host-to-machine port forwarding
- local port conflicts
- Podman networking or rootless port publishing

Clean up afterward:

```bash
podman rm -f podman-connectivity-test
```

Why this is useful:

- it removes Vault, Keycloak, Compose, and bind mounts from the equation
- it proves whether basic container port publishing works through the Podman machine

---

## Troubleshooting

### Podman machine is too small

Symptoms:

- service startups are slow
- Ollama crashes or is killed
- Keycloak becomes unstable

Fix:

- recreate or resize the machine
- use 8 GB RAM and 8 vCPU as the baseline

### Compose feature mismatch

Symptoms:

- services ignore health-gated ordering
- networks behave unexpectedly
- bind mounts fail

Check:

- which Compose implementation you are actually using
- its compatibility with the Compose file features in this repository

### Port binding failures

Symptoms:

- frontend, backend, Vault, or Keycloak fails to start

Check host-side conflicts for:

- `3000`
- `5432`
- `8081`
- `8082`
- `8088`
- `8200`
- `11434`
- `1389`
- `1636`

### Storage pressure

Symptoms:

- model pulls fail
- image builds fail
- volumes grow unexpectedly

Check:

```bash
podman system df
```

### Source changes do not appear inside backend or frontend

Check:

- the repo path is correctly mounted into the Podman machine
- bind mounts are working
- restart the affected service

```bash
podman compose restart backend
podman compose restart frontend
```
