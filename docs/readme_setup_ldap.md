# setup_ldap.sh — LDAP Bootstrap Script

**Location:** `scripts/setup_ldap.sh`
**Data file:** `ldap/bootstrap.ldif`

This script populates the OpenLDAP directory with the workshop's users and groups. It reads a single LDIF file, splits it into individual entries, and adds each one to the directory — skipping entries that already exist. Run it once after the stack is up, before running `setup_keycloak.sh`.

---

## Why LDAP?

LDAP (Lightweight Directory Access Protocol) is an industry-standard protocol for storing and querying identity information — users, groups, and their attributes. Many organisations run a central LDAP directory (like Microsoft Active Directory or OpenLDAP) as the authoritative source of user identities.

In this workshop, OpenLDAP acts as that central identity store. Keycloak federates against it, meaning Keycloak delegates user lookups to LDAP instead of managing its own user database. This mirrors how real enterprise identity stacks are built.

The chain is:

```
OpenLDAP (source of truth)
    ↓ federation (sync)
Keycloak (authentication + JWT issuance)
    ↓ JWT with role claims
Backend (authorisation decisions)
    ↓ role → Vault DB role
PostgreSQL (Row Level Security)
```

---

## Configuration defaults

```bash
LDAP_HOST="${LDAP_HOST:-localhost}"
LDAP_PORT="${LDAP_PORT:-1389}"
LDAP_ADMIN_DN="${LDAP_ADMIN_DN:-cn=admin,dc=my,dc=org}"
LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:-admin}"
LDAP_BASE_DN="${LDAP_BASE_DN:-dc=my,dc=org}"
LDIF_FILE="${LDIF_FILE:-ldap/bootstrap.ldif}"
```

All values use `:-` default syntax — they work as-is for the workshop but can be overridden:

```bash
LDAP_HOST=myldapserver LDAP_PORT=389 ./scripts/setup_ldap.sh
```

| Variable | Default | Meaning |
|----------|---------|---------|
| `LDAP_HOST` | `localhost` | Hostname of the OpenLDAP server |
| `LDAP_PORT` | `1389` | Port mapped to the host (container internal is 389) |
| `LDAP_ADMIN_DN` | `cn=admin,dc=my,dc=org` | Distinguished name used to authenticate to LDAP |
| `LDAP_ADMIN_PASSWORD` | `admin` | Password for the admin DN |
| `LDAP_BASE_DN` | `dc=my,dc=org` | Root of the directory tree to search |
| `LDIF_FILE` | `ldap/bootstrap.ldif` | The file containing all entries to load |

> **Port note:** The `docker-compose.yml` maps container port `389` to host port `1389`. The default `LDAP_PORT=1389` is for running the script from your laptop. Inside the Docker network, services talk to each other on port `389`.

---

## Helper functions

### `log` / `fail`

```bash
log()  { echo; echo "[LDAP] $1"; }
fail() { echo "ERROR: $1" >&2; exit 1; }
```

`log` prefixes output with `[LDAP]` so it is easy to spot in combined output. `fail` writes to stderr and exits immediately — the script will never continue past an error.

### `require_cmd`

```bash
require_cmd() {
  command -v "$1" >/dev/null || fail "Missing command: $1"
}
```

Checks that a binary is available on `PATH` before any real work starts. If `ldapadd` or `ldapsearch` are not installed, the script exits with a clear message rather than failing mid-way.

### `ldap_ok`

```bash
ldap_ok() {
  ldapsearch -x -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "$LDAP_ADMIN_DN" \
    -w "$LDAP_ADMIN_PASSWORD" \
    -b "$LDAP_BASE_DN" >/dev/null 2>&1
}
```

A connectivity check. Runs a search against the base DN and throws away the output — the only thing that matters is whether the command succeeds. If LDAP is not reachable, `ldap_ok` returns a non-zero exit code and `fail` is called.

The flags mean:
- `-x` — simple authentication (username + password, not SASL)
- `-H ldap://...` — the server URL
- `-D` — the bind DN (who you are logging in as)
- `-w` — the password

### `entry_exists`

```bash
entry_exists() {
  local dn="$1"
  ldapsearch -x -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "$LDAP_ADMIN_DN" \
    -w "$LDAP_ADMIN_PASSWORD" \
    -b "$dn" >/dev/null 2>&1
}
```

Checks whether a specific DN already exists in the directory by searching for it directly. The `-b` flag sets the **search base** — the exact DN to look up. If the search returns zero results, `ldapsearch` exits non-zero and the entry is considered absent.

This is how the script achieves idempotency — it never tries to add something that is already there.

---

## What the `setup` function does

### 1. Dependency and connectivity checks

```bash
require_cmd ldapadd
require_cmd ldapsearch
ldap_ok || fail "Cannot connect to LDAP"
```

Ensures both LDAP tools are installed and the server is reachable before touching anything.

### 2. Split the LDIF file into individual entries

```bash
awk 'BEGIN { RS=""; FS="\n" } { print > ("ldap_entry_" NR ".ldif") }' "$LDIF_FILE"
```

This is the most important line in the script. LDIF files use **blank lines as separators** between entries. This `awk` command:

- Sets the record separator (`RS`) to an empty string, which tells awk that blank lines divide records
- Prints each record (entry) to its own numbered temporary file: `ldap_entry_1.ldif`, `ldap_entry_2.ldif`, etc.

Why split? Because `ldapadd` would fail the entire file if any single entry already exists. By processing one entry at a time, the script can skip existing entries and continue.

### 3. Process each entry

```bash
for f in ldap_entry_*.ldif; do
  dn=$(grep '^dn:' "$f" | head -1 | cut -d' ' -f2-)

  if entry_exists "$dn"; then
    log "Skipping existing entry: $dn"
  else
    log "Adding entry: $dn"
    ldapadd -x -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
      -D "$LDAP_ADMIN_DN" \
      -w "$LDAP_ADMIN_PASSWORD" \
      -f "$f"
  fi

  rm "$f"
done
```

For each temporary file:

1. Extract the DN from the first `dn:` line
2. Check if that DN already exists in the directory
3. If it exists — log and skip
4. If it does not exist — call `ldapadd -f` to add it
5. Delete the temporary file regardless (cleanup)

`ldapadd` is the standard tool for adding entries to an LDAP directory from a LDIF file. The flags are the same connection parameters as `ldapsearch`.

---

## The bootstrap data — `ldap/bootstrap.ldif`

The LDIF file defines the entire directory structure: two organisational units, six users, and four groups.

### LDIF format primer

An LDIF entry looks like this:

```ldif
dn: uid=alice,ou=people,dc=my,dc=org
objectClass: inetOrgPerson
objectClass: posixAccount
cn: Alice
uid: alice
userPassword: alice123
```

- `dn` — the **Distinguished Name**, the unique path to this entry in the tree (like a file path)
- `objectClass` — defines which attributes the entry is allowed (and required) to have
- Each remaining line is an `attribute: value` pair

Blank lines separate entries.

### Directory structure

```
dc=my,dc=org                          ← domain root
├── ou=people                         ← organisational unit for users
│   ├── uid=repping  (Raymon Epping)
│   ├── uid=depping  (Duncan Epping)
│   ├── uid=cojan    (Cojan van Ballegooijen)
│   ├── uid=alice
│   ├── uid=bob
│   └── uid=charlie
└── ou=groups                         ← organisational unit for groups
    ├── cn=developers
    ├── cn=admin
    ├── cn=support
    └── cn=viewer
```

### Object classes used

| Object class | Purpose |
|-------------|---------|
| `inetOrgPerson` | Standard internet person — provides `cn`, `sn`, `mail`, `uid` |
| `posixAccount` | Unix-style account — provides `uidNumber`, `gidNumber`, `homeDirectory` |
| `top` | Root of the LDAP object class hierarchy — required by many schemas |
| `organizationalUnit` | Container for grouping entries (the `ou=people` and `ou=groups` nodes) |
| `posixGroup` | Unix-style group — uses `memberUid` to list members by username |

### Users

| uid | Name | Password | Email |
|-----|------|----------|-------|
| `repping` | Raymon Epping | `password` | repping@my.org |
| `depping` | Duncan Epping | `password` | depping@my.org |
| `cojan` | Cojan van Ballegooijen | `password` | cojan@my.org |
| `alice` | Alice | `alice123` | alice@my.org |
| `bob` | Bob | `bob123` | bob@my.org |
| `charlie` | Charlie | `charlie123` | charlie@my.org |

### Groups and membership

Groups use `memberUid` to list members by their `uid` value (not full DN). This is the `posixGroup` convention.

| Group | Members | Workshop role |
|-------|---------|--------------|
| `developers` | all six users | no special role |
| `admin` | repping, depping | `admin` → full DB access |
| `support` | repping, depping, cojan | `support` → public + internal rows |
| `viewer` | all six users | `viewer` → public rows only |

Users in multiple groups inherit the highest-privilege role. So `repping` (in `admin`, `support`, and `viewer`) gets the `admin` role.

---

## How roles flow from LDAP to the database

The groups defined here are the start of the privilege chain that runs through the entire stack:

```
LDAP group membership
    ↓  (Keycloak syncs groups via setup_keycloak.sh)
Keycloak group → realm role mapping
    ↓  (user logs in, Keycloak issues JWT)
JWT "roles" claim: ["admin"] / ["support"] / ["viewer"]
    ↓  (backend/auth.js verifies token)
Backend maps role → Vault DB role name
    ↓  (Vault database secrets engine)
Short-lived Postgres credential for: admin-read / support-read / viewer-read
    ↓  (PostgreSQL Row Level Security)
Queries filtered by classification: all rows / public+internal / public only
```

Changing a user's group membership in LDAP and re-syncing Keycloak is all it takes to change what data they can access — no application code changes needed.

---

## How to run it

Run from the project root with the stack up:

```bash
cd /path/to/zero_trust
./scripts/setup_ldap.sh
```

The script must be run from a machine that has `ldapadd` and `ldapsearch` installed, and can reach `localhost:1389`.

To run against a different host:

```bash
LDAP_HOST=myserver LDAP_PORT=389 ./scripts/setup_ldap.sh
```

To use a different LDIF file (e.g. to add more users):

```bash
LDIF_FILE=ldap/extra_users.ldif ./scripts/setup_ldap.sh
```

The script is **idempotent** — running it twice is safe. Entries that already exist are detected and skipped without error.

---

## Prerequisites

| Requirement | Why |
|-------------|-----|
| `ldapadd` | Adds new entries to the LDAP directory |
| `ldapsearch` | Checks connectivity and whether entries exist |
| `zero_trust_openldap` container running | The LDAP server must be up and listening |

Install on macOS:
```bash
brew install openldap
```

Install on Ubuntu/Debian:
```bash
sudo apt-get install ldap-utils
```

---

## Troubleshooting

**`Missing command: ldapadd`**
Install the OpenLDAP client utilities (you do not need the full server).

**`Cannot connect to LDAP`**
The OpenLDAP container is not reachable. Check it is running (`docker compose up openldap`) and that port 1389 is published. Verify with:
```bash
docker ps | grep openldap
```

**`ldap_entry_*.ldif: No such file or directory`** (loop error)
The LDIF file path is wrong. The script expects to be run from the project root (`zero_trust/`), not from inside `scripts/`. Check your working directory.

**Entries show as skipped but Keycloak sync finds no users**
The entries exist in LDAP but something is wrong with the Keycloak federation config. Run `setup_keycloak.sh` to (re)configure the LDAP provider and trigger a fresh sync.

**Verifying the directory contents manually:**
```bash
ldapsearch -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=my,dc=org" \
  -w admin \
  -b "dc=my,dc=org" \
  "(objectClass=*)"
```

Or use the phpLDAPadmin web UI at `http://localhost:8081` — log in as `cn=admin,dc=my,dc=org` with password `admin`.
