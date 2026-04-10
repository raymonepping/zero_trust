# verify_ldap.sh

**Location:** `scripts/verify_ldap.sh`  
**Audience:** students and engineers

This script performs a small set of LDAP sanity checks to confirm that the local OpenLDAP setup is ready for [scripts/setup_ldap.sh](../scripts/setup_ldap.sh).

It is intentionally narrow. It does not attempt to prove that every workshop user or group exists. It verifies the prerequisites that `setup_ldap.sh` depends on:

- required host tools are installed
- the bootstrap LDIF file exists
- the OpenLDAP container is running
- the admin bind works against the published host port
- the expected top-level directory branches are reachable
- Docker port publishing looks correct

It does not modify LDAP.

---

## When to use it

Use this script when:

- `setup_ldap.sh` fails immediately
- `ldapadd` or `ldapsearch` behavior looks inconsistent across machines
- you want to confirm the basic LDAP stack before starting the identity part of the workshop
- a colleague says LDAP is "up" but `setup_ldap.sh` still cannot run

---

## Usage

From the repository root:

```bash
./scripts/verify_ldap.sh
```

The script uses workshop defaults unless you override them with environment variables.

---

## Defaults and inputs

The script uses these defaults:

```bash
LDAP_HOST=127.0.0.1
LDAP_PORT=1389
LDAP_ADMIN_DN=cn=admin,dc=my,dc=org
LDAP_ADMIN_PASSWORD=admin
LDAP_BASE_DN=dc=my,dc=org
LDIF_FILE=ldap/bootstrap.ldif
LDAP_CONTAINER=zero_trust_openldap
```

These line up with:

- [docker-compose.yml](../docker-compose.yml)
- [scripts/setup_ldap.sh](../scripts/setup_ldap.sh)
- [ldap/bootstrap.ldif](../ldap/bootstrap.ldif)

You can override them if needed. Example:

```bash
LDAP_PORT=389 LDAP_HOST=my-ldap-host ./scripts/verify_ldap.sh
```

---

## What the script checks

### 1. Required commands

The script requires:

- `docker`
- `ldapsearch`
- `ldapadd`

These are the same tool assumptions made by [scripts/setup_ldap.sh](../scripts/setup_ldap.sh). If one of them is missing, there is no point continuing.

### 2. Bootstrap LDIF file

The script checks that the expected LDIF file exists:

```text
ldap/bootstrap.ldif
```

If this file is missing, `setup_ldap.sh` cannot populate the directory.

### 3. OpenLDAP container state

The script inspects:

```text
zero_trust_openldap
```

and prints:

- container name
- runtime status
- health status when available

This confirms whether the directory service is actually running before attempting host-side LDAP queries.

### 4. LDAP admin bind test

This is the core readiness check. The script performs an authenticated bind using:

- host `127.0.0.1`
- port `1389`
- admin DN `cn=admin,dc=my,dc=org`
- base DN `dc=my,dc=org`

If this fails, `setup_ldap.sh` will also fail.

### 5. Expected branch check

The script queries for `organizationalUnit` objects below the base DN. In the workshop that should include:

- `ou=people`
- `ou=groups`

This is useful because it confirms the directory tree is shaped the way the rest of the workshop expects.

### 6. Container port mapping

The script runs:

```bash
docker port zero_trust_openldap
```

This is a host-side sanity check that Docker is exposing LDAP on the expected ports:

- `1389` for LDAP
- `1636` for LDAPS

---

## Example output shape

Typical output looks like:

```text
==> LDAP bootstrap file
==> OpenLDAP container status
==> LDAP host bind test
==> LDAP expected branch check
==> OpenLDAP container port mapping
==> Summary
```

That is enough to answer the preflight question:

> Can `setup_ldap.sh` run successfully from this machine against this stack?

---

## How to interpret results

### Case: bind works and branches exist

This is the good path. The local LDAP stack is ready and `setup_ldap.sh` should be able to run.

### Case: `Required command not found: ldapsearch` or `ldapadd`

The local LDAP client tools are missing.

Typical fixes:

```bash
brew install openldap
```

or on Debian/Ubuntu:

```bash
sudo apt-get install ldap-utils
```

### Case: admin bind fails

This usually means one of:

- the OpenLDAP container is not running
- Docker is not publishing the expected port
- the admin DN or password is wrong
- another local LDAP service is already using the same port

Useful follow-up commands:

```bash
docker ps --format "table {{.Names}}\t{{.Ports}}"
docker logs zero_trust_openldap
```

### Case: container is running but branch check fails

That usually means the LDAP service is reachable, but the directory structure is not what the workshop expects. At that point:

- inspect [ldap/bootstrap.ldif](../ldap/bootstrap.ldif)
- rerun [scripts/setup_ldap.sh](../scripts/setup_ldap.sh)
- or inspect entries manually with `ldapsearch`

---

## What the script does not check

This script does not:

- add LDAP entries
- verify every workshop user exists
- verify every workshop group exists
- validate Keycloak federation
- validate JWT issuance

Those are later-layer concerns. This script is only about basic LDAP readiness.

---

## Related documents

- [scripts/verify_ldap.sh](../scripts/verify_ldap.sh)
- [scripts/setup_ldap.sh](../scripts/setup_ldap.sh)
- [docs/readme_setup_ldap.md](./readme_setup_ldap.md)
- [docker-compose.yml](../docker-compose.yml)
- [ldap/bootstrap.ldif](../ldap/bootstrap.ldif)
