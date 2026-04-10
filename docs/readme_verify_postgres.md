# verify_postgresql.sh

**Location:** `scripts/verify_postgresql.sh`  
**Audience:** students and engineers

This script verifies that the workshop PostgreSQL service is wired the way the stack expects:

- the Compose file declares the `db_data` volume
- the runtime created the matching named volume
- the `zero_trust_db` container is mounted to that volume
- PostgreSQL is reachable with the workshop defaults
- the expected workshop roles exist
- the main public tables exist

It is a diagnostic script. It does not modify the database, recreate containers, or remove volumes.

---

## When to use it

Use this script when:

- `psql` connections fail unexpectedly
- a colleague reports `role "appuser" does not exist`
- the workshop backend cannot connect to PostgreSQL
- you suspect Docker or Podman is publishing the wrong PostgreSQL instance
- you want to confirm whether the base database is healthy before running Vault phase 02

---

## Usage

From the repository root:

```bash
./scripts/verify_postgresql.sh
```

To use Podman explicitly:

```bash
./scripts/verify_postgresql.sh --runtime podman
```

The default runtime is `docker`.

---

## What the script checks

### 1. Compose volume declaration

The script starts with:

```bash
docker compose config --volumes
```

or the Podman equivalent. It verifies that `db_data` is declared in [docker-compose.yml](../docker-compose.yml).

If `db_data` is missing from the Compose output, the Compose file is wrong or you are not running the script against the expected repository.

### 2. Named volume existence

The script then looks for the runtime volume:

```bash
zero_trust_db_data
```

That is the workshop PostgreSQL named volume derived from:

- project name: `zero_trust`
- Compose volume name: `db_data`

If the volume does not exist, PostgreSQL has not been started yet or the stack was created under a different Compose project name.

### 3. Volume inspection

The script inspects the volume metadata so you can confirm:

- the real runtime volume name
- the mountpoint on the host
- the Compose labels attached to it

This is useful when someone says "the database is fresh" but they are actually reusing an older persisted volume.

### 4. Container mount inspection

The script inspects the `zero_trust_db` container to confirm that:

- the volume is mounted into the container
- the target path is `/var/lib/postgresql/data`

That path matters because the official PostgreSQL image only uses the `POSTGRES_*` environment variables on the first initialization of that data directory.

### 5. PostgreSQL connectivity

If `psql` is available on the host, the script runs a connectivity probe against:

- host: `127.0.0.1`
- port: `5432`
- database: `appdb`
- user: `appuser`

These defaults come from the workshop Compose configuration.

The connectivity query prints:

- current database
- current user
- PostgreSQL version

This tells you whether you are actually reaching the expected PostgreSQL instance.

### 6. Workshop role check

The script checks these roles:

- `appuser`
- `viewer-read`
- `support-read`
- `admin-read`

Interpret them carefully:

- `appuser` is part of the base PostgreSQL setup
- `viewer-read`, `support-read`, and `admin-read` are created later by [scripts/setup_vault.sh](../scripts/setup_vault.sh) phase 02

So:

- if `appuser` is missing, the PostgreSQL cluster was initialized incorrectly or you are hitting the wrong instance
- if only `viewer-read`, `support-read`, and `admin-read` are missing, PostgreSQL is probably fine and Vault phase 02 has simply not been run yet

### 7. Public table inventory

The script lists all tables in the `public` schema.

This helps separate three different states:

1. PostgreSQL exists, but the workshop data was never seeded
2. PostgreSQL exists and the data is present
3. you are connected to some other PostgreSQL instance entirely

---

## Environment overrides

The script supports these optional overrides:

```bash
PGHOST
PGPORT
PGDATABASE
PGUSER
PGPASSWORD
CONTAINER_RUNTIME
```

Example:

```bash
PGPORT=15432 ./scripts/verify_postgresql.sh
```

That is useful when the local host port was remapped or when Docker and Podman are both installed and you want to test a non-default endpoint.

---

## Example output shape

Typical output sections look like this:

```text
==> Compose volumes
==> Matching volume
==> Inspecting volume zero_trust_db_data
==> Inspecting container mounts for zero_trust_db
==> PostgreSQL connectivity check
==> PostgreSQL workshop role check
==> PostgreSQL public table inventory
```

This structure is intentional. It narrows failures from the outside inward:

1. Compose declaration
2. runtime volume
3. container mount
4. database login
5. role state
6. schema state

---

## Common interpretations

### Case: `role "appuser" does not exist`

This is a base PostgreSQL initialization problem, not a Vault problem.

Likely causes:

- the data volume was initialized differently in the past
- you are connecting to the wrong PostgreSQL instance on the host
- a stale host port mapping is sending traffic somewhere else

Recommended checks:

```bash
./scripts/verify_postgresql.sh
docker ps --format "table {{.Names}}\t{{.Ports}}"
docker exec -it zero_trust_db psql -U appuser -d appdb -c '\du'
```

If the in-container check also fails and the local database can be reset:

```bash
docker compose down
docker volume rm zero_trust_db_data
docker compose up -d db
```

This removes the persisted PostgreSQL data and forces first-time initialization to run again.

### Case: `viewer-read`, `support-read`, or `admin-read` are missing

This usually means PostgreSQL is fine, but Vault phase 02 has not been run yet.

Run:

```bash
source ./scripts/vault_login.sh
./scripts/setup_vault.sh --phase 02
```

### Case: tables are missing

This usually means the database exists but the workshop data has not been seeded yet.

Run:

```bash
./scripts/seed_db.sh
```

### Case: host-side `psql` fails but in-container `psql` works

That is usually a host routing or port conflict issue.

Check:

```bash
docker ps --format "table {{.Names}}\t{{.Ports}}"
lsof -iTCP:5432 -sTCP:LISTEN -n -P
docker port zero_trust_db
```

At that point the Compose database is probably fine and the host is connecting to the wrong service.

---

## Why the script disables the pager

The `psql` calls use:

```bash
-X
-P pager=off
```

This keeps the script non-interactive and avoids the `:q` or pager prompt behavior that would otherwise make it awkward in terminal sessions or shared troubleshooting output.

---

## What the script does not do

This script does not:

- recreate containers
- remove volumes
- reseed the database
- apply Vault roles
- repair networking automatically

That is deliberate. A verification script should diagnose state first, not mutate it.

---

## Related documents

- [README.md](../README.md)
- [docker-compose.yml](../docker-compose.yml)
- [scripts/verify_postgresql.sh](../scripts/verify_postgresql.sh)
- [docs/readme_seed_db.md](./readme_seed_db.md)
- [docs/readme_setup_vault.md](./readme_setup_vault.md)
- [docs/readme_docker.md](./readme_docker.md)
- [docs/readme_podman.md](./readme_podman.md)
