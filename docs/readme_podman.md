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
- [Compatibility Notes](#compatibility-notes)
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
