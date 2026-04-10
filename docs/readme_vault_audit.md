# audit_log.sh — Vault Audit Log Viewer

**Location:** `scripts/audit_log.sh`
**Companion script:** `scripts/rotate_vault_audit.sh`
**Requires:** Phase 06 of `setup_vault.sh` (audit logging must be enabled)

This script streams and filters the Vault audit log in real time. Every authentication, secret read, credential issuance, and revocation Vault performs is recorded in the audit log as a JSON line. This script makes that stream readable by parsing each entry with `jq` and presenting only the fields that matter.

---

## Why audit logging matters

Every other script in this workshop teaches how to *obtain* credentials securely. The audit log is how you *prove* credentials were used correctly — and how you detect when they were not.

Vault's audit log is:

- **Tamper-evident** — entries are append-only; Vault cannot delete or modify existing entries
- **Complete** — every request and response is logged, including denied ones
- **Non-repudiable** — each entry contains a request ID linking request and response, a timestamp, the caller's entity, the path accessed, and the operation performed
- **Safe** — secret values are never written; tokens and sensitive fields are HMAC-hashed

In a real security incident, the audit log is how you answer: *"Who accessed what, when, and did they succeed?"*

---

## Enabling audit logging

Audit logging is set up by Phase 06 of `setup_vault.sh`:

```bash
./scripts/setup_vault.sh --phase 06
```

This runs:

```bash
vault audit enable file \
  file_path=/vault/audit/vault-audit.log \
  log_raw=false \
  hmac_accessor=true
```

| Setting | Value | Effect |
|---------|-------|--------|
| `file_path` | `/vault/audit/vault-audit.log` | Written inside the container; volume-mounted to `vault/audit/` on the host |
| `log_raw=false` | | Secret values in requests/responses are **not** written to the log |
| `hmac_accessor=true` | | Token accessors are hashed — they cannot be used to look up tokens from the log alone |

> **Important:** If audit logging is enabled and the log file becomes unwritable (disk full, permissions issue), Vault **stops serving all requests**. Vault treats a failed audit write as a security failure — it would rather refuse requests than operate without an audit trail. Keep an eye on disk space.

---

## How to use audit_log.sh

### Default — stream everything live

```bash
./scripts/audit_log.sh
```

Tails the log file in real time (like `tail -f`). Every new entry is parsed and pretty-printed as it arrives. Press `Ctrl+C` to stop.

### Filter by event type

```bash
./scripts/audit_log.sh --type request    # only inbound requests
./scripts/audit_log.sh --type response   # only responses (includes auth result)
```

Every log entry is either a `request` (Vault received a call) or a `response` (Vault answered it). Requests and responses share the same `request.id`, so you can match them up. Filtering to `response` is useful when you want to see outcomes — which requests were allowed vs. denied.

### Filter by path prefix

```bash
./scripts/audit_log.sh --path database/
./scripts/audit_log.sh --path auth/jwt/
./scripts/audit_log.sh --path secret/
./scripts/audit_log.sh --path sys/leases/
```

Restricts output to entries where `request.path` starts with the given prefix. This is the most useful filter for the workshop — you can watch exactly which credential paths the backend is hitting.

Common paths you will see:

| Path prefix | What it means |
|-------------|--------------|
| `auth/jwt/login` | Backend exchanging a Keycloak JWT for a Vault token |
| `auth/approle/login` | Backend logging in via AppRole |
| `database/creds/` | Dynamic DB credential being issued |
| `secret/data/` | KV secret being read |
| `sys/leases/revoke` | A credential lease being explicitly revoked |
| `auth/token/renew-self` | The backend renewing its Vault token |
| `auth/token/lookup-self` | The backend checking its token is still valid |

### Filter by operation

```bash
./scripts/audit_log.sh --op read     # credential reads, KV reads
./scripts/audit_log.sh --op write    # logins, policy writes, config changes
./scripts/audit_log.sh --op delete   # revocations, deletions
./scripts/audit_log.sh --op list     # listing paths
```

Vault maps HTTP verbs to named operations. `read` covers `GET` requests, `write` covers `POST`/`PUT`, `delete` covers `DELETE`. Note that JWT logins show as `write` (because they POST to `auth/jwt/login`) even though conceptually they are an authentication operation.

### Combine filters

Flags compose — all active filters are ANDed together:

```bash
# Watch only write credentials being issued
./scripts/audit_log.sh --type request --path database/creds/ --op read

# See all JWT logins
./scripts/audit_log.sh --path auth/jwt/login --op write

# See lease revocations
./scripts/audit_log.sh --path sys/leases/revoke
```

### Show the last N lines then follow

```bash
./scripts/audit_log.sh --lines 20
```

Shows the 20 most recent entries, then continues streaming. Useful when you rejoin a running session and want context before watching live.

### Print and exit (no follow)

```bash
./scripts/audit_log.sh --no-follow
./scripts/audit_log.sh --no-follow --path database/creds/ --lines 50
```

Prints matching entries and exits immediately. Useful for scripting or quick inspection.

---

## How the filtering works internally

The script builds a `jq` filter expression dynamically based on the flags provided:

```bash
JQ_FILTER="."

# --type request
JQ_FILTER+=" | select(.type == \"request\")"

# --path database/
JQ_FILTER+=" | select(.request.path | startswith(\"database/\"))"

# --op read
JQ_FILTER+=" | select(.request.operation == \"read\")"
```

The filters chain with `|` — each one receives only the entries that passed the previous filter. The final expression is passed to `jq` as a single pipeline.

After filtering, a formatting step extracts and renames the fields that matter:

```jq
{
  time:      .time,
  type:      .type,
  op:        .request.operation,
  path:      .request.path,
  entity:    (.auth.entity_id // .auth.display_name // "(anonymous)"),
  policy:    (.auth.policy_results.allowed // null),
  remote_ip: .request.remote_address,
  error:     (.error // null)
}
```

The `//` operator is jq's null-coalescing — it tries the left side, and if it is null or missing, uses the right side. `entity` tries three fields in order: `entity_id`, `display_name`, then falls back to `"(anonymous)"` for unauthenticated requests.

---

## Understanding the log format

The raw audit log is one JSON object per line. Here is a real entry, annotated:

```json
{
  "type": "response",                          ← request or response
  "time": "2026-04-03T18:31:43.292Z",          ← UTC timestamp

  "auth": {
    "display_name": "jwt-repping@my.org",      ← who made the request
    "entity_id": "cf237dc3-7d28-...",          ← Vault entity UUID
    "policies": ["default","zero-trust-jwt-lab"], ← policies in effect
    "token_ttl": 900,                          ← token TTL in seconds (15 min)
    "token_type": "service",
    "client_token": "hmac-sha256:859a2a...",   ← token HMAC (not the real token)
    "policy_results": { "allowed": true }      ← was the request permitted?
  },

  "request": {
    "id": "2875dd62-06d9-c057-...",            ← links request ↔ response pair
    "operation": "read",                       ← read / write / delete / list
    "path": "database/creds/support-read",     ← which Vault path
    "remote_address": "10.89.3.27",            ← caller's IP (backend container)
    "mount_type": "database",                  ← which secrets engine
    "mount_point": "database/"
  },

  "error": null                                ← error message if denied
}
```

### What is HMAC-hashed?

Fields like `client_token` and `accessor` are never written as plain values — they are replaced with `hmac-sha256:<hash>`. The hash is computed using a per-audit-device salt that only Vault knows. This means:

- Reading the log does not reveal usable tokens
- The same token produces the same hash on every entry, so you can correlate all requests made by the same token across the log
- You cannot reverse the hash to recover the original token

Secret values in request data (passwords, JWT contents) are handled the same way when they appear in log entries — they are hashed, not omitted.

---

## Workshop exercises — what to look for

### Watch the backend authenticate on each request (jwt-roles connector)

```bash
./scripts/audit_log.sh --path auth/jwt/login
```

You should see a `request` + `response` pair every time a user makes an API call. The `display_name` field shows which user's JWT was used (`jwt-repping@my.org`, `jwt-alice@my.org`, etc.).

### Watch dynamic credentials being issued

```bash
./scripts/audit_log.sh --path database/creds/
```

Each credential request appears as a `read` operation on `database/creds/<role-name>`. Notice the path changes based on which user is logged in — `support-read` for a support user, `viewer-read` for a viewer.

### Watch the CIBA write credential lifecycle

```bash
./scripts/audit_log.sh --path database/creds/support-write
```

For the `jwt-ciba` connector, you should see the `support-write` credential requested after a CIBA approval, then a `sys/leases/revoke` entry shortly after as the backend immediately revokes it.

```bash
./scripts/audit_log.sh --path sys/leases/
```

### Watch a denied request

Try accessing the API as a `viewer` user and requesting data that should be filtered by RLS. The Vault layer will still issue a `viewer-read` credential — the denial happens in Postgres via RLS, not in Vault. But if you try to request a credential for the wrong role (e.g. a viewer trying to get `admin-read`), that denial *will* appear in the Vault audit log with `"allowed": false` and an error message.

### Correlate a request and its response

Every log entry has a `request.id`. A `request` entry and its `response` entry share the same ID:

```bash
./scripts/audit_log.sh --no-follow | jq 'select(.path == "auth/jwt/login")' | head -4
# Find the request.id value, then:
cat vault/audit/vault-audit.log | jq 'select(.request.id == "<your-id>")'
```

---

## Rotating the audit log

Log files grow indefinitely. The companion script `rotate_vault_audit.sh` handles rotation safely using the correct Unix pattern for log rotation with a running process.

```bash
./scripts/rotate_vault_audit.sh             # rotate, keep 7 archived files
./scripts/rotate_vault_audit.sh --keep 14   # keep 14 archived files
```

### What it does

**1. Move the current log to a timestamped filename:**

```bash
mv /vault/audit/vault-audit.log \
   /vault/audit/vault-audit.20260410-143022.log
```

This is done *inside* the container (the volume is shared, but the move must happen where the file lives).

**2. Send SIGHUP to the Vault process:**

```bash
kill -HUP $(pgrep -x vault)
```

`SIGHUP` (Signal Hang Up) is a Unix signal traditionally used to tell a process to re-read its configuration or reopen its log files. Vault handles it by closing the current audit file handle and opening a new one at the original path (`vault-audit.log`). After the signal, Vault resumes writing to the new file immediately — no requests are dropped or delayed.

> This is the correct way to rotate logs for any long-running process: move the file first, then signal the process to reopen. If you just deleted the file, Vault would keep writing to the deleted inode until it closed the file handle — and you would lose those entries.

**3. Prune old rotated files:**

```bash
ls -1t vault-audit.*.log | tail -n ${EXCESS} | xargs rm -f
```

Lists rotated files sorted newest-first (`-1t`), takes the oldest N (`tail`), and removes them. The `--keep` argument (default: 7) sets how many archived files to retain.

### Setting up automatic rotation (cron)

The script's header suggests a daily cron job:

```bash
0 0 * * * /path/to/zero_trust/scripts/rotate_vault_audit.sh >> /var/log/vault-rotate.log 2>&1
```

This runs at midnight every day, appending output to a rotation log. For a workshop, manual rotation is fine — for a production system, automating this prevents the disk from filling up and blocking Vault.

---

## Reading the raw log directly

The audit log is volume-mounted at `vault/audit/vault-audit.log` on the host, so you can also read it directly:

```bash
# Pretty-print the last 10 entries
tail -10 vault/audit/vault-audit.log | jq .

# Count events by path
cat vault/audit/vault-audit.log \
  | jq -r '.request.path' \
  | sort | uniq -c | sort -rn

# Find all denied requests
cat vault/audit/vault-audit.log \
  | jq 'select(.auth.policy_results.allowed == false)'

# Find all credential issuances for a specific user
cat vault/audit/vault-audit.log \
  | jq 'select(.auth.display_name | startswith("jwt-repping"))'
  | jq '{time, path: .request.path, op: .request.operation}'

# Count credential issuances by role
cat vault/audit/vault-audit.log \
  | jq -r 'select(.request.path | startswith("database/creds/")) | .request.path' \
  | sort | uniq -c | sort -rn
```

---

## Quick reference

| Command | What you see |
|---------|-------------|
| `./scripts/audit_log.sh` | All events, live |
| `./scripts/audit_log.sh --path auth/` | All authentication events |
| `./scripts/audit_log.sh --path database/creds/` | All credential issuances |
| `./scripts/audit_log.sh --path sys/leases/` | All lease operations (revocations) |
| `./scripts/audit_log.sh --type response --no-follow` | All completed events, exit after |
| `./scripts/audit_log.sh --op write --path auth/` | Logins only |
| `./scripts/rotate_vault_audit.sh` | Rotate log, keep 7 archives |
| `./scripts/rotate_vault_audit.sh --keep 30` | Rotate log, keep 30 archives |

---

## Prerequisites

| Requirement | Why |
|-------------|-----|
| `docker` | Reads log file from inside the Vault container |
| `jq` | Parses and formats the JSON log entries |
| Phase 06 of `setup_vault.sh` complete | Audit logging must be enabled in Vault |
| Vault container running | The script reads from the live container |

---

## Troubleshooting

**`container 'zero_trust_vault' is not running`**
Start the stack: `docker compose up -d vault`, then unseal with `./scripts/unseal_vault.sh`.

**No output after starting**
Audit logging may not be enabled. Run `./scripts/setup_vault.sh --phase 06`. Verify with:
```bash
vault audit list
```

**Output is blank lines only**
The audit log file exists but is empty — no requests have been made since the last rotation, or audit logging was just enabled. Make an API call (e.g. open the frontend) and entries should appear.

**`jq: error`**
A log entry was truncated (possible if the disk was full mid-write). Identify the bad line with:
```bash
cat vault/audit/vault-audit.log | while IFS= read -r line; do
  echo "$line" | jq . >/dev/null 2>&1 || echo "Bad line: $line"
done
```
