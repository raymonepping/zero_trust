# setup_ciba.sh — CIBA Vault Configuration Script

**Location:** `scripts/setup_ciba.sh`
**Workshop phase:** Phase 7 (the final and most advanced phase)
**Companion script:** `scripts/setup_ciba_keycloak.sh`

This script extends the Vault configuration with a **write-scoped database role** specifically for the CIBA (Client-Initiated Backchannel Authentication) connector. It adds a `support-write` role that grants narrowly scoped, very short-lived write credentials — issued only after a user explicitly approves an elevated action through a separate authentication channel.

Run `setup_vault.sh --phase 02` and `--phase 04` before running this script.

---

## What is CIBA?

CIBA stands for **Client-Initiated Backchannel Authentication**. It is an OpenID Connect extension that separates *requesting an action* from *approving that action*.

In the standard OIDC flow, the same user who logs in also immediately approves all the permissions their token grants. CIBA breaks this apart:

```
Standard flow:
  User logs in → gets token → token permits everything

CIBA flow:
  Agent (backend) wants to do something elevated
      ↓
  Agent sends a CIBA request to Keycloak: "I want to update an order on behalf of repping"
      ↓
  Keycloak notifies the user: "The system wants to update order #42. Approve?"
      ↓
  User explicitly approves (on their phone, in the UI, etc.)
      ↓
  Only now is a write credential issued — for that specific action, valid for 5 minutes
```

This is sometimes called **delegated authority** or **step-up authentication**. The user's normal read-only session continues unaffected. The write credential is additional, narrowly scoped, and requires active consent.

---

## Where CIBA fits in the workshop progression

| Phase | Connector | Auth method | DB access |
|-------|-----------|------------|-----------|
| 0 | `wired` | None (hardcoded) | Full |
| 1 | `vault` | KV token | Static |
| 2 | `dynamic` | Vault token | Dynamic read/write |
| 3a | `approle` | AppRole | Static KV |
| 3b | `approle-dynamic` | AppRole | Dynamic full |
| 4 | `approle-rotation` | AppRole + renewal | Dynamic full |
| 5 | `jwt-rotation` | Keycloak JWT | Dynamic read |
| 6 | `jwt-roles` | Keycloak JWT + role scoping | Role-scoped read |
| **7** | **`jwt-ciba`** | **Keycloak JWT + CIBA approval** | **Role-scoped read + approved write** |

Phase 7 is the most secure pattern: reads and writes use completely separate credentials. Writes require a second factor — explicit user approval through the CIBA backchannel.

---

## Pre-requisite check

Before doing any configuration, the script verifies that the necessary Vault infrastructure from earlier phases is in place:

```bash
vault secrets list | grep -q "^database/"
vault auth list    | grep -q "^jwt/"
vault read database/config/postgres
```

If any of these checks fail, the script exits with a clear message pointing to which `setup_vault.sh` phase to run first. There is no point creating a `support-write` role if the database secrets engine or JWT auth method does not yet exist.

---

## What the script configures — step by step

### Step 1 — PostgreSQL group role: `support-write`

```sql
CREATE ROLE "support-write" NOLOGIN;
GRANT USAGE ON SCHEMA public TO "support-write";
GRANT SELECT, UPDATE ON orders TO "support-write";
```

This creates a group role in PostgreSQL — a template, not a login account. It grants exactly two privileges on exactly one table:

| Permission | Table | Why |
|-----------|-------|-----|
| `SELECT` | `orders` | The write credential needs to read order state |
| `UPDATE` | `orders` | The specific elevated action: changing order status |

Everything else is denied. The `support-write` role cannot touch `users`, `preferences`, `training`, `tickets`, or `projects`. It cannot `INSERT` or `DELETE` — not even on `orders`. This is the narrowest possible write scope for this use case.

Compare this to the read roles from phase 02:

| Role | Tables accessible | Operations |
|------|------------------|------------|
| `viewer-read` | `users`, `orders` (RLS: public only) | SELECT |
| `support-read` | 6 tables (RLS: public + internal) | SELECT |
| `admin-read` | All tables | SELECT |
| **`support-write`** | **`orders` only** | **SELECT, UPDATE** |

A write role that can only touch one table with one write operation is far safer than a broader role that has been granted write access as an afterthought.

### Step 2 — Update the Vault database connection

```bash
vault write database/config/postgres \
  allowed_roles="app-role,viewer-read,support-read,admin-read,support-write"
```

The Vault database connection has a safelist of permitted roles. `support-write` must be added before Vault will generate credentials for it. This is an explicit allowlist — Vault refuses to generate credentials for any role not named here, even if the role exists in Postgres.

### Step 3 — Vault database role: `support-write`

```bash
vault write database/roles/support-write \
  db_name=postgres \
  default_ttl="5m" \
  max_ttl="15m" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' \
    VALID UNTIL '{{expiration}}' IN ROLE \"support-write\"; \
    GRANT SELECT, UPDATE ON orders TO \"{{name}}\";" \
  revocation_statements="..."
```

Key design decisions in this role:

**Very short TTL — 5 minutes default, 15 minutes maximum.**
Write credentials should be as short-lived as possible. A read credential lasting an hour is acceptable; a write credential that lingers for an hour is a liability. The 5-minute TTL forces the backend to re-request a credential for each write operation, and the credential is revoked as soon as the operation completes.

**`IN ROLE "support-write"` inherits the group role's grants.**
The generated user inherits `SELECT, UPDATE ON orders` from the group role, plus the explicit grants in the `creation_statements`. Even if the explicit grants were accidentally dropped, the inherited group role still restricts access correctly.

**`VALID UNTIL '{{expiration}}'` is a hard Postgres expiry.**
Even if Vault's lease tracking fails, the Postgres user itself becomes invalid at the same time. Two independent enforcement points.

**Explicit revocation statements.**
When Vault revokes the lease (on expiry, on demand, or on rotation), it runs the `revocation_statements` to drop the Postgres user. This leaves no orphaned accounts in the database.

### Step 4 — Policy update: `zero-trust-jwt-lab`

The existing JWT policy (created in `setup_vault.sh --phase 04`) is rewritten to add the `support-write` path:

```hcl
# New addition
path "database/creds/support-write" {
  capabilities = ["read"]
}
```

The capability is `read` — "read" in Vault's policy language means "fetch this resource", which for a `database/creds/` path means "issue a new credential". It does not mean the credential itself is read-only.

All existing paths are preserved:

| Path | What it grants |
|------|---------------|
| `database/creds/app-role` | General dynamic credential |
| `database/creds/viewer-read` | Viewer-scoped read credential |
| `database/creds/support-read` | Support-scoped read credential |
| `database/creds/admin-read` | Admin-scoped read credential |
| `database/creds/support-write` | **CIBA write credential (new)** |
| `auth/token/lookup-self` | Token introspection |
| `auth/token/renew-self` | Token renewal |
| `sys/leases/revoke` | Explicit lease revocation |
| `sys/leases/lookup` | Lease status lookup |

---

## Smoke tests

After configuration, the script runs three automated verification tests to confirm everything works end-to-end.

### Test 1 — Issue a write credential

```bash
vault read -format=json database/creds/support-write
```

Requests a real `support-write` credential from Vault. If the role is misconfigured or the database connection is broken, this fails here rather than at runtime.

### Test 2 — Verify UPDATE works

```bash
UPDATE orders SET status = 'processing' WHERE id = 1 RETURNING id;
```

Connects to Postgres as the just-issued dynamic user and runs an UPDATE. Confirms the credential actually has write permission on `orders`.

### Test 3 — Verify INSERT on users is denied

```bash
INSERT INTO users (first_name, last_name, email, ...) VALUES (...);
```

Attempts an operation the credential should *not* be allowed to perform. The test asserts that Postgres returns a `permission denied` error. This confirms the scope is correctly restricted — the credential cannot escape to other tables.

### Cleanup

```bash
vault lease revoke "${WRITE_LEASE}"
```

Immediately revokes the test credential after verification. It is not left to expire naturally. This mirrors how the production flow should work — credential obtained, action performed, credential revoked.

---

## The full CIBA flow in production

After running this script and `setup_ciba_keycloak.sh`, the `jwt-ciba` connector enables this end-to-end flow:

```
1. User logs in → Keycloak issues JWT with role claim
        ↓
2. Backend uses JWT to get a read credential (support-read)
   User browses orders normally
        ↓
3. User triggers an order status update
        ↓
4. Backend initiates CIBA with Keycloak:
   "User repping wants to update order #42 to 'shipped'. Please authenticate."
        ↓
5. Keycloak sends a backchannel request to backend's /ciba/request endpoint
   User sees an approval prompt
        ↓
6. User explicitly approves the action
        ↓
7. Backend receives approval, polls Keycloak, gets a CIBA token
        ↓
8. Backend requests database/creds/support-write from Vault
   TTL: 5 minutes — just long enough for the write
        ↓
9. Backend uses write credential to UPDATE orders SET status = 'shipped'
        ↓
10. Backend immediately revokes the lease: vault lease revoke <lease_id>
    The Postgres user is dropped
        ↓
11. Full audit trail in Vault audit log:
    who requested, which credential, which lease, when revoked
```

Steps 8–11 happen within a single request cycle. The write credential exists for seconds, not minutes.

---

## Why this matters — the security principle

Every previous phase improved *how* the backend authenticates to Vault. CIBA changes *when* credentials are elevated — introducing a human approval gate between normal operation and write access.

Without CIBA, a compromised backend token (or a bug in the application) could immediately issue write credentials and modify data. With CIBA, a write requires:

1. A valid user session with the right role
2. An explicit in-band approval from the actual user
3. Vault to issue a credential with a 5-minute lifespan
4. The backend to immediately revoke it after use

An attacker who steals the backend's Vault token can still only read data — they cannot write without triggering a user-visible approval request. The user's approval is the second factor.

---

## How to run it

Ensure phases 02 and 04 of `setup_vault.sh` have been completed, then:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<your-token>

./scripts/setup_ciba.sh
```

Then configure Keycloak:

```bash
./scripts/setup_ciba_keycloak.sh
```

Then switch the connector:

```bash
./scripts/switch_connector.sh --replace-with jwt-ciba
```

---

## Testing the full flow

`scripts/test_ciba.sh` runs an automated end-to-end test of the complete CIBA flow — login, initiate, approve, poll, write, verify. Use it to confirm everything is wired up correctly:

```bash
./scripts/test_ciba.sh
```

It tests all seven steps: JWT acquisition, CIBA initiation, AD delegation handling, approval, session polling, write execution, and verification.

---

## Prerequisites

| Requirement | Why |
|-------------|-----|
| `vault` CLI on PATH | Configures Vault roles and policies |
| `psql` installed | Creates the PostgreSQL group role |
| `VAULT_ADDR` + `VAULT_TOKEN` exported | Authenticates to Vault |
| `setup_vault.sh --phase 02` complete | Database secrets engine must exist |
| `setup_vault.sh --phase 04` complete | JWT auth method must exist |
| Database container running | `psql` must reach Postgres |

---

## Troubleshooting

**`Database secrets engine not found`**
Run `./scripts/setup_vault.sh --phase 02` first.

**`JWT auth method not found`**
Run `./scripts/setup_vault.sh --phase 04` first.

**`psql: connection refused`**
The database container is not running. Start it with `docker compose up -d db`.

**Smoke test 2 fails (cannot UPDATE orders)**
The PostgreSQL group role was not granted correctly. Check grants:
```bash
docker exec -it zero_trust_db psql -U appuser -d appdb -c "\dp orders"
```

**Smoke test 3 warns about unexpected permissions**
The `support-write` role may have inherited broader permissions from a previous schema change. Review grants with `\du support-write` inside psql.

**CIBA approval prompt never appears**
`setup_ciba_keycloak.sh` must be run after this script, and Keycloak must be started with the CIBA SPI argument pointing to `http://backend:3000/ciba/request`. Check `docker-compose.yml` for the `--spi-ciba-auth-channel-...` command line argument on the Keycloak service.
