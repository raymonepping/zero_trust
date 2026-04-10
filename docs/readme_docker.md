# Docker Environment Prerequisites

**Stack definition:** `docker-compose.yml`

This document explains what a machine needs in order to run the Zero Trust Workshop with Docker. It is written for students setting up the lab for the first time and for engineers operating or validating the environment.

The goal is practical clarity:

- what must be installed
- how much CPU, memory, disk, and network access the stack needs
- which ports are used
- which Docker commands are useful during setup and operation

No sensitive values are included here.

---

## Table Of Contents

- [Purpose](#purpose)
- [What Runs In This Stack](#what-runs-in-this-stack)
- [Required Software](#required-software)
- [Machine Sizing](#machine-sizing)
- [Ports And Network Requirements](#ports-and-network-requirements)
- [Storage Requirements](#storage-requirements)
- [Required Local Files And Directories](#required-local-files-and-directories)
- [Recommended Docker Workflow](#recommended-docker-workflow)
- [Useful Docker And Compose Commands](#useful-docker-and-compose-commands)
- [Operational Notes](#operational-notes)
- [Troubleshooting](#troubleshooting)

---

## Purpose

The workshop is a multi-container stack. It is not just one API and one UI.

From `docker-compose.yml`, the environment includes:

- PostgreSQL
- Vault
- Vault Agent
- Ollama
- backend
- frontend
- OpenLDAP
- LDAP Admin
- Keycloak

That means the host must support:

- multiple long-running containers
- several persistent volumes
- local image builds
- internal service-to-service networking
- at least one service with noticeable memory demand (`ollama`)

---

## What Runs In This Stack

The Compose stack defines these services:

| Service | Purpose | Host Port |
| ------- | ------- | --------- |
| `db` | PostgreSQL data store | `5432` |
| `vault` | Vault server | `8200` |
| `vault-agent` | renders dynamic DB creds to shared volume | none |
| `ollama` | local LLM runtime | `11434` |
| `backend` | Express API | `3000` |
| `frontend` | Vite UI | `8088` by default |
| `openldap` | LDAP directory | `1389`, `1636` |
| `ldap-admin` | phpLDAPadmin UI | `8081` |
| `keycloak` | OIDC and CIBA provider | `8082` |

There are also four Docker networks:

- `net-frontend`
- `net-backend`
- `net-data`
- `net-egress`

and seven named volumes:

- `db_data`
- `vault_data`
- `vault-agent-secrets`
- `ollama_data`
- `openldap-data`
- `openldap-config`
- `keycloak_data`

---

## Required Software

Minimum Docker-side prerequisites:

- Docker Engine or Docker Desktop
- Docker Compose v2 (`docker compose`)

Recommended checks:

```bash
docker version
docker compose version
```

The workshop also assumes your Docker environment can:

- build local images from `./db` and `./ollama`
- pull published images for backend and frontend
- mount local directories into containers
- create named volumes and bridge networks

If you are using Linux, your shell user must be able to access the Docker daemon without permission issues.

---

## Machine Sizing

This stack is not especially CPU-heavy except when Ollama is active, but it is not a tiny stack either.

### Recommended baseline

- **CPU:** 6 vCPU minimum, 8 vCPU recommended
- **Memory:** 8 GB usable for the container runtime
- **Disk:** 40 GB minimum free space, 60+ GB recommended if you rebuild often or keep multiple images

### Why 8 GB is a reasonable target

From `docker-compose.yml`:

- `ollama` declares a memory limit of `4G`
- `ollama` declares a CPU limit of `3.0`
- the rest of the stack includes PostgreSQL, Keycloak, Vault, frontend, backend, LDAP, and LDAP admin

In practice, 8 GB is a reasonable workshop target because:

- Ollama is the largest consumer
- the remaining services are comparatively modest
- you still need headroom for Docker itself and filesystem cache

For students on tighter machines:

- 6 GB may work for partial workflows
- 8 GB is the safer number for the full stack

### CPU guidance

Use 8 vCPU if available. The stack will usually run with less, but 8 keeps:

- Ollama responsive
- Keycloak startup tolerable
- backend/frontend hot-reload smoother

---

## Ports And Network Requirements

The stack binds these host ports:

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

### Host-side requirement

These ports must be free, or Compose will fail to start the corresponding service.

Check current use:

```bash
lsof -iTCP -sTCP:LISTEN -n -P
```

### Network requirement

Internet access is primarily needed for:

- pulling container images
- pulling Ollama models
- npm package install during image builds if cache is cold

The application itself is mostly isolated onto internal Docker bridge networks after startup.

---

## Storage Requirements

Persistent storage matters for this workshop because multiple services keep data locally.

### Main disk consumers

- `ollama_data`  
  model weights are often the largest persistent artifact

- `db_data`  
  PostgreSQL data

- `vault_data`  
  Vault raft/file storage

- `keycloak_data`  
  realm and identity data

- local Docker image cache  
  especially if you rebuild backend, frontend, db, or ollama images repeatedly

### Recommended free space

- **Minimum:** 40 GB free
- **More comfortable:** 60 GB or more

If you frequently rebuild images, rotate tags, or keep old models around, expect storage pressure sooner.

Useful inspection commands:

```bash
docker system df
docker volume ls
docker images
```

---

## Required Local Files And Directories

From the Compose file, the environment expects several local repo paths to exist and be readable.

Important examples:

- `./backend`
- `./frontend`
- `./db`
- `./ollama`
- `./vault/config.hcl`
- `./vault/config/vault.hclic`
- `./vault-agent/config`
- `.env`

Important note:

- the Vault license file path is required by Compose
- this document does not include the file contents

The environment also relies on bind mounts for live development:

- `./backend:/app`
- `./frontend:/app`

That means local source edits affect the running containers directly.

---

## Recommended Docker Workflow

Typical workshop flow:

### 1. Validate Docker

```bash
docker version
docker compose version
```

### 2. Start the foundation services

```bash
docker compose up -d db openldap ldap-admin keycloak
```

### 3. Seed and configure the lab

Run the repository setup scripts from the host shell as described in the workshop docs.

### 4. Start backend and frontend

```bash
docker compose up -d backend frontend
```

### 5. Add Vault-related services when progressing the labs

```bash
docker compose up -d vault vault-agent
```

### 6. Start the full stack when needed

```bash
docker compose up -d
```

---

## Useful Docker And Compose Commands

### Basic lifecycle

```bash
docker compose up -d
docker compose down
docker compose stop
docker compose start
docker compose restart
```

### Targeted service control

```bash
docker compose up -d backend frontend
docker compose restart backend
docker compose restart frontend
docker compose logs -f backend
docker compose logs -f keycloak
```

### Status and inspection

```bash
docker compose ps
docker ps
docker stats --no-stream
docker system df
docker network ls
docker volume ls
```

### Health and debug

```bash
docker exec -it zero_trust_backend sh
docker exec -it zero_trust_db sh
docker exec -it zero_trust_vault sh
docker logs zero_trust_backend
docker logs zero_trust_keycloak
```

### Rebuild when needed

```bash
docker compose build
docker compose build db ollama
docker compose up -d --build
```

### Cleanup

```bash
docker compose down -v
docker image prune
docker volume prune
docker system prune
```

Use cleanup commands carefully. Named volumes contain workshop state.

---

## Operational Notes

### Frontend and backend are bind-mounted on purpose

The running containers use the checked-out source tree for:

- `./backend`
- `./frontend`

That is why connector swaps and frontend edits take effect quickly without rebuilding images.

### Ollama is the resource anchor

If the environment feels heavy, Ollama is the first place to look:

- startup time
- memory usage
- model download size

### Internal networks are intentional

The Compose file uses internal bridge networks for most traffic. The browser only reaches published host ports. Services communicate with each other through Docker networking, not through host loopback.

### Health checks matter

Several services use health checks and `depends_on` conditions. If one core service is unhealthy, downstream services may wait or restart later than expected.

---

## Troubleshooting

### Port already in use

Symptoms:

- Compose fails during startup
- a service will not bind its published port

Check:

```bash
lsof -iTCP -sTCP:LISTEN -n -P
```

### Docker has insufficient memory

Symptoms:

- Ollama fails to start
- Keycloak is slow or unstable
- builds are killed unexpectedly

Fix:

- increase Docker memory allocation
- stop unrelated containers

### Disk pressure

Symptoms:

- image pulls fail
- builds fail mid-layer
- container writes fail

Check:

```bash
docker system df
df -h
```

### Permission errors on bind mounts

More likely on Linux hosts.

Check:

- repo directory ownership
- Docker daemon access
- SELinux/AppArmor behavior if applicable

### Backend or frontend code changes do not appear

Check:

- bind mounts are active
- the service is actually running
- restart the affected service:

```bash
docker compose restart backend
docker compose restart frontend
```
