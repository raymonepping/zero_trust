# setup_keycloak.sh — Keycloak Configuration Script

**Location:** `scripts/setup_keycloak.sh`

This script wires Keycloak into the workshop stack. It creates the realm, connects Keycloak to LDAP, registers the frontend and backend as OIDC clients, defines roles, and maps those roles to LDAP groups. You run it once after the stack is up — or any time you need to rebuild the Keycloak configuration from scratch.

---

## Why Keycloak?

Keycloak is an open-source **Identity Provider (IdP)**. In this workshop it does two things:

1. **Authenticates users** — when a user logs in to the frontend, Keycloak validates their username and password (sourced from LDAP) and issues a **JWT (JSON Web Token)**.
2. **Declares who they are** — the JWT includes a `roles` claim (`admin`, `support`, or `viewer`). The backend reads this claim and maps it to a scoped Vault database role, controlling exactly which data the user's database connection can see.

The full flow looks like this:

```
User logs in → Keycloak (validates via LDAP) → issues JWT
     ↓
Frontend sends JWT as Bearer token → Backend
     ↓
Backend verifies JWT → reads role claim → requests Vault creds for that role
     ↓
Vault issues short-lived DB credential scoped to that role
     ↓
PostgreSQL enforces Row Level Security for that role
```

---

## Configuration defaults

```bash
KEYCLOAK_URL="${KC_URL:-http://localhost:8080}"
ADMIN_USER="${KC_ADMIN_USER:-admin}"
ADMIN_PASS="${KC_ADMIN_PASS:-admin}"
KEYCLOAK_CONTAINER="${KC_CONTAINER:-zero_trust_keycloak}"
TARGET_REALM="zero-trust"
PROVIDER_NAME="openldap"
FRONTEND_CLIENT_ID="zero-trust-app"
BACKEND_CLIENT_ID="backend"
REALM_ROLES=(admin support viewer)
```

Every connection parameter can be overridden via environment variable. The defaults match the workshop's `docker-compose.yml`. To point at a different Keycloak instance:

```bash
KC_URL=http://myserver:8080 KC_ADMIN_PASS=mysecret ./scripts/setup_keycloak.sh
```

**Command-line flags** (equivalent to env vars):

| Flag | Short | Purpose |
|------|-------|---------|
| `--url` | `-u` | Keycloak base URL |
| `--admin-user` | `-U` | Admin username |
| `--admin-pass` | `-P` | Admin password |
| `--container` | `-c` | Docker container name |
| `--help` | `-h` | Show usage |

---

## Helper functions

Before the main logic, several small functions are defined that the rest of the script reuses.

### `kcadm`

```bash
kcadm() { docker exec "${KEYCLOAK_CONTAINER}" /opt/keycloak/bin/kcadm.sh "$@"; }
```

`kcadm` (Keycloak Admin CLI) is Keycloak's built-in command-line administration tool. This wrapper runs it **inside the Docker container** so you do not need to install it locally. Every Keycloak operation in this script goes through this wrapper.

### `log` / `ok` / `skip` / `fail`

Simple output formatters that prefix messages with `[KC]`, `✓`, `–`, or `ERROR:` to make the script's progress easy to read. `fail` also exits immediately with a non-zero code.

### `ensure_client`

```bash
ensure_client CLIENT_ID NAME PUBLIC STANDARD_FLOW DIRECT_GRANTS \
  [AUTH_TYPE] [REDIRECT_URIS] [WEB_ORIGINS] [ATTRIBUTES]
```

A reusable function that creates or updates an OIDC client. The key logic:

1. Check if the client already exists by querying the Keycloak API and filtering with `jq`
2. **If it exists** — update it in place (idempotent update)
3. **If it does not exist** — create it, then fetch its generated UUID for follow-up updates

The function also applies optional properties — redirect URIs, web origins, PKCE settings — as separate `kcadm update` calls so the logic stays clean.

### `get_client_uuid` / `get_client_secret`

Helpers that look up a client's internal UUID (needed to call sub-resources like `/client-secret`) and retrieve the auto-generated client secret after creation.

### `ensure_realm_role`

Idempotent role creation — checks if the role exists before creating it. This prevents errors when the script is run a second time.

### `ensure_group_has_role`

Looks up a Keycloak group by name (after LDAP sync has pulled it in), then assigns a realm role to that group. This is what makes group membership in LDAP automatically grant a role in Keycloak.

---

## What the script does — step by step

### Step 0: Prerequisites

```bash
require_cmd docker
require_cmd jq
docker inspect "${KEYCLOAK_CONTAINER}" >/dev/null 2>&1 || fail "..."
```

- Checks that `docker` and `jq` are installed
- Verifies the Keycloak container is actually running
- Waits up to 30 seconds for Keycloak's HTTP endpoint to respond

---

### Step 1: Authenticate

```bash
kcadm config credentials \
  --server  "${KEYCLOAK_URL}" \
  --realm   master \
  --user    "${ADMIN_USER}" \
  --password "${ADMIN_PASS}"
```

Logs in to the `master` realm (Keycloak's built-in admin realm) using the bootstrap admin credentials. This stores a session token that `kcadm` reuses for all subsequent calls — you only authenticate once.

> The `master` realm is Keycloak's own administrative realm. The workshop realm (`zero-trust`) is a separate, isolated realm created in the next step.

---

### Step 2: Create the realm

```bash
kcadm create realms \
  -s realm="zero-trust" \
  -s enabled=true \
  -s displayName="Zero Trust Workshop" \
  -s registrationAllowed=false \
  -s loginWithEmailAllowed=true \
  -s sslRequired=external
```

A **realm** in Keycloak is a completely isolated tenant — its own users, clients, roles, and identity providers. The workshop uses the `zero-trust` realm so it does not interfere with anything in `master`.

Settings applied:
- `registrationAllowed=false` — users cannot self-register; all accounts come from LDAP
- `loginWithEmailAllowed=true` — users can log in with their email address instead of their username
- `sslRequired=external` — TLS is required for external (non-localhost) connections, but not for internal Docker-to-Docker traffic

---

### Step 3: Resolve the realm UUID

```bash
REALM_ID=$(kcadm get "realms/${TARGET_REALM}" --fields id --format csv --noquotes)
```

Keycloak's API uses internal UUIDs for references between objects. This step fetches the realm's UUID to use as `parentId` when creating the LDAP provider in the next step.

---

### Step 4: Create the LDAP user federation provider

This is where Keycloak learns about LDAP. Keycloak calls external user sources **User Storage Providers**, and the one for LDAP is configured here.

Key settings:

| Setting | Value | Meaning |
|---------|-------|---------|
| `connectionUrl` | `ldap://openldap:389` | OpenLDAP container on the internal Docker network |
| `usersDn` | `ou=people,dc=my,dc=org` | Where to search for users |
| `usernameLDAPAttribute` | `uid` | LDAP field that maps to the Keycloak username |
| `uuidLDAPAttribute` | `entryUUID` | Unique identifier for each LDAP entry |
| `authType` | `simple` | Bind with a DN and password (as opposed to anonymous) |
| `bindDn` | `cn=admin,dc=my,dc=org` | The admin account used to read LDAP |
| `editMode` | `READ_ONLY` | Keycloak cannot write back to LDAP |
| `importEnabled` | `true` | LDAP users are copied into Keycloak's local database on sync |

The LDAP directory structure is:

```
dc=my,dc=org
├── ou=people          ← users live here
│   ├── uid=repping
│   ├── uid=depping
│   ├── uid=cojan
│   ├── uid=alice
│   ├── uid=bob
│   └── uid=charlie
└── ou=groups          ← groups live here
    ├── cn=admin       → memberUid: repping, depping
    ├── cn=support     → memberUid: repping, depping, cojan
    ├── cn=viewer      → memberUid: repping, depping, cojan, alice, bob, charlie
    └── cn=developers  → (all users)
```

---

### Step 5: Create the LDAP group mapper

The group mapper tells Keycloak how to read LDAP groups and map them to Keycloak groups.

Key settings:

| Setting | Value | Meaning |
|---------|-------|---------|
| `groups.dn` | `ou=groups,dc=my,dc=org` | Where groups are in LDAP |
| `group.object.classes` | `posixGroup` | The LDAP object class for groups |
| `membership.attribute.type` | `UID` | Groups store member usernames, not full DNs |
| `membership.ldap.attribute` | `memberUid` | The LDAP attribute listing group members |
| `mode` | `READ_ONLY` | Keycloak cannot modify LDAP groups |

Without this mapper, Keycloak would import users from LDAP but would not know about group membership.

---

### Step 6: Create OIDC clients

Two clients are registered. In OIDC, a **client** represents an application that will request tokens from Keycloak.

#### Frontend client: `zero-trust-app`

```bash
ensure_client "zero-trust-app" "Zero Trust App" \
  true  \   # publicClient — no client secret (browser app)
  true  \   # standardFlowEnabled — authorization code flow
  true  \   # directAccessGrantsEnabled — username/password flow (for testing)
  ""    \   # no client authenticator
  '["http://localhost:5173/*","http://localhost:3000/*"]' \
  '["http://localhost:5173","http://localhost:3000"]' \
  '{"pkce.code.challenge.method":"S256"}'
```

- **Public client** — the frontend runs in the browser; there is nowhere safe to store a secret, so none is used
- **PKCE** (Proof Key for Code Exchange) — a security extension for public clients that prevents authorization code interception attacks. The frontend generates a random code challenge; Keycloak verifies it when exchanging the code for a token

#### Backend client: `backend`

```bash
ensure_client "backend" "backend" \
  false \   # confidential client — has a secret
  true  \   # standardFlowEnabled
  true  \   # directAccessGrantsEnabled
  client-secret
```

- **Confidential client** — the backend runs server-side, so a client secret is safe to store
- The backend uses this client to verify tokens and to call Keycloak's token introspection endpoint
- The client secret is auto-generated and printed at the end of the script — copy it to your `.env` as `KEYCLOAK_CLIENT_SECRET`

---

### Step 7: Create realm roles

```bash
REALM_ROLES=(admin support viewer)
for role_name in "${REALM_ROLES[@]}"; do
  ensure_realm_role "${role_name}"
done
```

Three **realm roles** are created: `admin`, `support`, and `viewer`. These roles are assigned to groups (in step 9), not directly to users. When a user is a member of the `admin` LDAP group, they inherit the `admin` realm role.

These role names match the Vault database roles and the PostgreSQL RLS policies:

| Keycloak role | Vault DB role | PostgreSQL policy | Can see |
|--------------|--------------|------------------|---------|
| `viewer` | `viewer-read` | `orders_viewer_policy` | `public` rows only |
| `support` | `support-read` | `orders_support_policy` | `public` + `internal` rows |
| `admin` | `admin-read` | `orders_admin_policy` | All rows |

---

### Step 8: Full LDAP sync

```bash
kcadm create "user-storage/${PROVIDER_ID}/sync?action=triggerFullSync" -r "${TARGET_REALM}" -o
```

Triggers Keycloak to immediately pull all users and groups from LDAP into its internal database. Without this, Keycloak knows about the LDAP server but has not yet imported anything. The sync must complete before step 9 can map groups to roles.

After the sync, all six workshop users (`repping`, `depping`, `cojan`, `alice`, `bob`, `charlie`) and all four groups (`admin`, `support`, `viewer`, `developers`) are visible in Keycloak.

---

### Step 9: Map LDAP groups to realm roles

```bash
for role_name in "${REALM_ROLES[@]}"; do
  ensure_group_has_role "${role_name}" "${role_name}"
done
```

Each LDAP group gets the corresponding realm role assigned:

- Group `admin` → role `admin`
- Group `support` → role `support`
- Group `viewer` → role `viewer`

From this point on, when any user in the `support` LDAP group logs in and requests a token, that token's `roles` claim will include `support`. The backend reads this claim from the JWT and knows which Vault role — and therefore which database credentials — to request.

---

### Final output

```
────────────────────────────────────────────────
 Realm 'zero-trust' is ready.
 Frontend Client ID : zero-trust-app
 Backend Client ID  : backend
 Backend Secret     : <generated secret>
 Keycloak  : http://localhost:8080/realms/zero-trust
────────────────────────────────────────────────
```

**The backend secret** is important — copy it to your `.env` file:

```bash
KEYCLOAK_CLIENT_SECRET=<the value printed here>
```

---

## The complete identity chain

After the script runs, here is how every piece connects:

```
LDAP (openldap)
  └─ groups: admin, support, viewer
        ↓ (synced by step 8)
Keycloak (zero-trust realm)
  └─ groups inherit realm roles: admin, support, viewer
        ↓ (JWT issued on login)
JWT token
  └─ claims: { "roles": ["support"] }
        ↓ (verified by backend/auth.js)
Backend (Node.js)
  └─ reads role → resolves Vault DB role (support-read)
        ↓
Vault (database secrets engine)
  └─ issues short-lived credential for role support-read
        ↓
PostgreSQL (RLS)
  └─ support-read can SELECT WHERE classification IN ('public', 'internal')
```

---

## Workshop user reference

All users have the password `password` (except alice/bob/charlie who use their name + `123`).

| Username | Password | Groups | Keycloak role | DB access |
|----------|----------|--------|--------------|-----------|
| `repping` | `password` | admin, support, viewer | `admin` | All rows |
| `depping` | `password` | admin, support, viewer | `admin` | All rows |
| `cojan` | `password` | support, viewer | `support` | public + internal |
| `alice` | `alice123` | viewer | `viewer` | public only |
| `bob` | `bob123` | viewer | `viewer` | public only |
| `charlie` | `charlie123` | viewer | `viewer` | public only |

> Users in multiple groups inherit the highest-privilege role.

---

## How to run it

Make sure the stack is running first:

```bash
docker compose up -d vault openldap keycloak
```

Then run the script:

```bash
cd /path/to/zero_trust
./scripts/setup_keycloak.sh
```

Or with overrides:

```bash
KC_URL=http://localhost:8082 ./scripts/setup_keycloak.sh
```

The script is **idempotent** — running it twice is safe. Existing objects are detected and skipped or updated rather than duplicated.

---

## Prerequisites

| Requirement | Why |
|-------------|-----|
| `docker` | All `kcadm` calls run inside the Keycloak container |
| `jq` | Parses JSON responses from the Keycloak Admin API |
| `zero_trust_keycloak` container running | The script execs into it |
| `zero_trust_openldap` container running | LDAP sync will fail if OpenLDAP is not up |

---

## Troubleshooting

**`Container 'zero_trust_keycloak' is not running`**
Start the stack: `docker compose up -d keycloak`

**Script hangs at "Waiting for Keycloak..."**
Keycloak can take 30–60 seconds to start. If it still does not respond, check its logs: `docker logs zero_trust_keycloak`. Common causes are the container still initialising, or a port conflict on 8082.

**`Expected LDAP-synced Keycloak group '...' to exist after sync`** (step 9)
The LDAP sync in step 8 did not import the group. Check that `zero_trust_openldap` is healthy and that `setup_ldap.sh` has been run to populate it with the bootstrap data.

**Backend says "invalid token" after login**
The `KEYCLOAK_CLIENT_SECRET` in your `.env` does not match the secret printed at the end of this script. Re-run the script, copy the printed secret, and restart the backend container.

**"already exists, skipping" for everything**
This is normal on a second run — the script found all objects already in place and skipped creation. Only creation-time errors are a problem.

**Checking what was created**
Open the Keycloak admin UI at `http://localhost:8082` (admin / admin), switch to the `zero-trust` realm, and browse Users, Groups, Roles, and Clients to verify the setup.
