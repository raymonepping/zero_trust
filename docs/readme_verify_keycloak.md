# verify_keycloak.sh

**Location:** `scripts/verify_keycloak.sh`  
**Audience:** students and engineers

This script performs a focused set of Keycloak sanity checks to confirm that the local Keycloak service is ready for [scripts/setup_keycloak.sh](../scripts/setup_keycloak.sh).

The goal is not to validate the full realm configuration. The goal is to prove that the basic setup path can run:

- required host tools exist
- the Keycloak container is running
- the LDAP dependency container is running
- the host URL is reachable
- the master realm OIDC metadata is live
- `kcadm.sh` exists in the container
- bootstrap admin authentication works

It does not create or update anything in Keycloak beyond performing an admin login sanity check.

---

## When to use it

Use this script when:

- `setup_keycloak.sh` fails early
- Keycloak is running but you are unsure whether it is actually ready
- a machine can reach `localhost:8082` in the browser but `kcadm.sh` automation still fails
- you want a quick preflight before configuring the realm, clients, and LDAP federation

---

## Usage

From the repository root:

```bash
./scripts/verify_keycloak.sh
```

The script uses workshop defaults unless you override them with environment variables.

---

## Defaults and inputs

The script uses these defaults:

```bash
KC_URL=http://localhost:8082
KC_ADMIN_USER=admin
KC_ADMIN_PASS=admin
KC_CONTAINER=zero_trust_keycloak
LDAP_CONTAINER=zero_trust_openldap
```

These align with:

- [docker-compose.yml](../docker-compose.yml)
- [scripts/setup_keycloak.sh](../scripts/setup_keycloak.sh)

You can override them if you need to point at a different local or remote Keycloak instance. Example:

```bash
KC_URL=http://localhost:18082 KC_ADMIN_PASS=otherpass ./scripts/verify_keycloak.sh
```

---

## What the script checks

### 1. Required commands

The script requires:

- `docker`
- `jq`
- `curl`

These are the minimum host-side dependencies used by the Keycloak setup flow and the verifier itself.

### 2. Keycloak container state

The script inspects:

```text
zero_trust_keycloak
```

and prints the runtime state. If the container has a Docker healthcheck defined, that health state is shown too. If not, the script only reports the runtime state and does not treat missing healthchecks as a problem.

### 3. OpenLDAP dependency state

The Keycloak workshop setup depends on LDAP being available for federation. The script therefore also inspects:

```text
zero_trust_openldap
```

This is not a full LDAP validation. It is just enough to confirm that the dependency container is up.

### 4. Host reachability

The script checks the configured host URL:

```text
http://localhost:8082
```

This confirms that Docker port publishing and host access are working for the Keycloak web service.

### 5. Master realm OIDC metadata

The script fetches:

```text
/realms/master/.well-known/openid-configuration
```

and prints a small subset:

- `issuer`
- `authorization_endpoint`
- `token_endpoint`

This is a practical readiness check. If the discovery document is live, Keycloak is serving the core OIDC endpoints correctly.

### 6. `kcadm.sh` inside the container

The setup script uses Keycloak's admin CLI from inside the container:

```text
/opt/keycloak/bin/kcadm.sh
```

The verifier checks that this executable exists.

This matters because [scripts/setup_keycloak.sh](../scripts/setup_keycloak.sh) is implemented around `docker exec ... kcadm.sh`, not around a host-installed Keycloak CLI.

### 7. Bootstrap admin login

The final and most important check is a login sanity call using:

- server `http://localhost:8080` inside the container
- realm `master`
- bootstrap admin username
- bootstrap admin password

If this succeeds, the core assumptions of [scripts/setup_keycloak.sh](../scripts/setup_keycloak.sh) are satisfied.

---

## Example output shape

Typical output looks like:

```text
==> Keycloak container status
==> OpenLDAP dependency container status
==> Keycloak host reachability
==> Keycloak master realm metadata
==> kcadm availability inside container
==> Keycloak admin login sanity
==> Summary
```

That is enough to answer the preflight question:

> Can `setup_keycloak.sh` run successfully against this local stack?

---

## How to interpret results

### Case: all checks pass

This is the normal path. Keycloak is reachable, the admin CLI is present, admin credentials work, and the setup script should be able to run.

### Case: host reachability fails

This usually means one of:

- Keycloak is still starting
- port `8082` is not published correctly
- another local service is using the same host port
- Docker or Podman networking is broken on that machine

Useful follow-up commands:

```bash
docker ps --format "table {{.Names}}\t{{.Ports}}"
docker logs zero_trust_keycloak
```

### Case: metadata fetch fails but the container is running

That usually means Keycloak is not fully ready yet, even though the process is running. Wait a bit longer and rerun the script.

### Case: `kcadm.sh` check fails

That means the container image does not match what the workshop expects. [scripts/setup_keycloak.sh](../scripts/setup_keycloak.sh) will fail too, because it uses `kcadm.sh` internally.

### Case: admin login sanity fails

That usually means one of:

- wrong bootstrap admin credentials
- Keycloak data volume contains a different admin state than expected
- the container was initialized differently on that machine

At that point, inspect:

```bash
docker logs zero_trust_keycloak
docker inspect zero_trust_keycloak --format '{{json .Config.Env}}'
```

---

## What the script does not check

This script does not:

- create the `zero-trust` realm
- verify that the realm already exists
- validate LDAP federation configuration
- validate frontend or backend OIDC clients
- validate realm roles
- validate CIBA configuration

Those are all later configuration steps handled by [scripts/setup_keycloak.sh](../scripts/setup_keycloak.sh) and [scripts/setup_ciba_keycloak.sh](../scripts/setup_ciba_keycloak.sh).

---

## Why the script checks both host and in-container behavior

The setup flow uses two different execution contexts:

- host-side HTTP checks against `http://localhost:8082`
- in-container `kcadm.sh` calls against `http://localhost:8080`

Both matter.

If the host URL works but the in-container admin CLI path or login fails, the setup script still will not run correctly. The verifier checks both so the failure surface is clear.

---

## Related documents

- [scripts/verify_keycloak.sh](../scripts/verify_keycloak.sh)
- [scripts/setup_keycloak.sh](../scripts/setup_keycloak.sh)
- [scripts/setup_ciba_keycloak.sh](../scripts/setup_ciba_keycloak.sh)
- [docs/readme_setup_keycloak.md](./readme_setup_keycloak.md)
- [docs/readme_setup_ldap.md](./readme_setup_ldap.md)
- [docker-compose.yml](../docker-compose.yml)
