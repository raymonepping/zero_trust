# rotate_vault_audit.sh — Vault Audit Log Rotation Script

**Location:** `scripts/rotate_vault_audit.sh`
**Related script:** `scripts/audit_log.sh` (for reading the log)
**Requires:** Phase 06 of `setup_vault.sh` (audit logging must be enabled)

This script safely rotates the Vault audit log. It renames the current log to a timestamped archive, signals Vault to reopen a fresh log file, and prunes old archives beyond a configurable retention limit. It can be run manually or on a cron schedule for automated daily rotation.

---

## Why log rotation exists

The Vault audit log is append-only and grows without bound. Left unmanaged it will eventually fill the disk — and when the disk fills, Vault stops serving all requests (because it cannot write to the audit log and treats that as a security failure).

Log rotation solves this by periodically archiving the current log and starting a fresh one. The archived files are kept for a configurable number of days and then pruned. This gives you a rolling history of audit events without unlimited disk growth.

In the workshop's `vault/audit/` directory you can see this pattern already at work:

```
vault/audit/
├── vault-audit.log                        ← live log, currently being written
└── vault-audit.20260403-201658.log        ← previous rotation archive (2.0 MB)
```

---

## The core problem: rotating logs for a running process

You cannot simply delete or truncate a log file that a running process has open. On Linux/macOS, when a process opens a file, the operating system gives it a **file descriptor** — a handle to the file's data on disk (the inode), not to the filename. If you delete or rename the file, the process still holds its descriptor open and keeps writing to the original inode. The data goes somewhere no filename points to, and is lost when the process eventually closes the handle.

The correct rotation pattern for any long-running process is:

```
1. Move (rename) the current log file to an archive name
2. Signal the process to close and reopen its log file
3. The process creates a new file at the original path and resumes writing
```

Step 2 is what distinguishes safe rotation from data loss. Vault handles `SIGHUP` by closing and reopening all audit file handles — exactly what is needed.

---

## Usage

```bash
# Basic rotation — keeps 7 archived files
./scripts/rotate_vault_audit.sh

# Keep more history
./scripts/rotate_vault_audit.sh --keep 14

# Automated daily rotation via cron (midnight every day)
0 0 * * * /path/to/zero_trust/scripts/rotate_vault_audit.sh >> /var/log/vault-rotate.log 2>&1
```

---

## Configuration

```bash
CONTAINER="${VAULT_CONTAINER:-zero_trust_vault}"
AUDIT_DIR="${AUDIT_DIR:-/vault/audit}"
AUDIT_FILE="${AUDIT_DIR}/vault-audit.log"
KEEP="${KEEP:-7}"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
```

All four values can be overridden via environment variables:

| Variable | Default | Meaning |
|----------|---------|---------|
| `VAULT_CONTAINER` | `zero_trust_vault` | Name of the running Vault Docker container |
| `AUDIT_DIR` | `/vault/audit` | Directory path *inside* the container |
| `KEEP` | `7` | How many rotated archive files to retain |
| `TIMESTAMP` | Current time | Format: `YYYYMMDD-HHMMSS` — embedded in archive filename |

The `AUDIT_DIR` path is inside the container. Because the audit directory is a Docker volume mount, the same files are visible on the host at `vault/audit/`.

The `--keep` flag overrides `KEEP` at runtime without needing to set an environment variable:

```bash
KEEP=30 ./scripts/rotate_vault_audit.sh
# or equivalently:
./scripts/rotate_vault_audit.sh --keep 30
```

---

## What the script does — step by step

### Step 1 — Container health check

```bash
docker inspect "${CONTAINER}" --format '{{.State.Running}}' | grep -q true
```

Before touching anything, the script confirms the Vault container is actually running. If it is not, there is no Vault process to signal in step 3, and the rotation would be incomplete. The script exits with an error rather than creating an orphaned archive file.

`docker inspect --format '{{.State.Running}}'` returns `true` or `false` from Docker's container state — a more reliable check than `docker ps` which can be slow or return stale data.

---

### Step 2 — Move the current log to a timestamped archive

```bash
ROTATED="${AUDIT_DIR}/vault-audit.${TIMESTAMP}.log"

docker exec "${CONTAINER}" mv "${AUDIT_FILE}" "${ROTATED}"
```

This renames the live log file inside the container. The `mv` command is atomic on most filesystems — the rename either completes fully or not at all, with no window where the file is partially moved.

After this line:
- `vault-audit.log` no longer exists at its original path
- `vault-audit.20260410-143022.log` (or whatever the timestamp is) holds all the previous log data
- Vault is still writing to the original inode via its open file descriptor — those writes go to the archive file, not lost

The archive file is named with a timestamp embedded:
```
vault-audit.20260410-143022.log
           ↑        ↑
           date     time (HHMMSS)
```

This makes archives sortable by filename, which the pruning step relies on.

---

### Step 3 — Send SIGHUP to Vault

```bash
docker exec "${CONTAINER}" sh -c 'kill -HUP $(pgrep -x vault)'
```

This is the critical step. Breaking it down:

**`pgrep -x vault`** — finds the process ID (PID) of the exact process named `vault` (the `-x` flag requires an exact match, so it does not match `vault-agent` or similar). Returns the PID number.

**`kill -HUP <pid>`** — sends signal 1 (`SIGHUP`, Signal Hang Up) to that process. Despite the name "Hang Up" (a legacy term from dial-up modems), modern daemons use this signal to mean "reload configuration" or "reopen log files".

**Vault's response to SIGHUP:** Vault closes its current audit file handle, then immediately opens the audit file path (`/vault/audit/vault-audit.log`) again. Because step 2 moved the old file, Vault creates a brand new, empty file at that path.

The time between step 2 (move) and step 3 (SIGHUP) is milliseconds. Any audit entries written during that window go to the archive file via the still-open file descriptor — they are not lost.

After SIGHUP, all new audit entries go to the fresh `vault-audit.log`. The transition is seamless from Vault's perspective; no requests are dropped or queued.

> **Why `sh -c '...'`?** The command substitution `$(pgrep ...)` requires a shell to interpret. `docker exec` by itself does not run a shell — it executes a binary directly. Wrapping the command in `sh -c '...'` gives it the shell it needs.

---

### Step 4 — Prune old archives

```bash
ROTATED_COUNT=$(docker exec "${CONTAINER}" sh -c \
  "ls -1 ${AUDIT_DIR}/vault-audit.*.log 2>/dev/null | wc -l" | tr -d '[:space:]')

if [[ "${ROTATED_COUNT}" -gt "${KEEP}" ]]; then
  EXCESS=$(( ROTATED_COUNT - KEEP ))
  docker exec "${CONTAINER}" sh -c \
    "ls -1t ${AUDIT_DIR}/vault-audit.*.log | tail -n ${EXCESS} | xargs rm -f"
fi
```

This block counts how many rotated archives exist and removes the oldest ones if the count exceeds `KEEP`.

Breaking down the pruning command:

**`ls -1t vault-audit.*.log`** — lists archive files one per line (`-1`), sorted newest-first by modification time (`-t`). Because archive filenames contain timestamps, time-sort and name-sort give the same result — but time-sort is authoritative.

**`tail -n ${EXCESS}`** — skips the newest `KEEP` files and prints only the oldest `EXCESS` files. For example, if `KEEP=7` and there are 9 archives, `EXCESS=2` and `tail` prints the two oldest filenames.

**`xargs rm -f`** — receives the filenames from `tail` and deletes them. The `-f` flag suppresses errors if a file was already deleted between the listing and the removal (a rare race condition in automated environments).

**`tr -d '[:space:]'`** — strips any whitespace (including newlines) from the count returned by `wc -l`. Some systems pad `wc` output with spaces; stripping them ensures the comparison `[[ "${ROTATED_COUNT}" -gt "${KEEP}" ]]` works correctly.

---

## Output example

```
[rotate] Starting Vault audit log rotation — Thu Apr 10 14:30:22 UTC 2026
[rotate] Container : zero_trust_vault
[rotate] Audit file: /vault/audit/vault-audit.log
[rotate] Keep      : 7 rotated files
[rotate] Moved to: /vault/audit/vault-audit.20260410-143022.log
[rotate] SIGHUP sent — Vault will create a new /vault/audit/vault-audit.log
[rotate] Pruning 1 old file(s) (keeping 7)...
[rotate] Done — Thu Apr 10 14:30:22 UTC 2026
```

Each line is prefixed with `[rotate]` so it is easy to identify in combined logs, especially when running as a cron job where the output is appended to a separate log file.

---

## Archive retention — choosing a `--keep` value

| `--keep` value | Retention at daily rotation | Practical use |
|---------------|---------------------------|---------------|
| `7` (default) | One week | Workshop / short-lived environments |
| `14` | Two weeks | Short project sprints |
| `30` | One month | Compliance minimum in many organisations |
| `90` | Three months | Standard security retention period |
| `365` | One year | Long-term audit requirements |

For the workshop, the default of 7 is appropriate — you are unlikely to need to look back more than a week. In a real production environment, retention requirements are usually set by compliance policy (PCI-DSS, SOC 2, ISO 27001 all have specific audit log retention requirements, commonly 90 days to one year).

---

## Setting up automated rotation

### Cron (system-level scheduling)

```bash
# Edit the crontab for the current user
crontab -e

# Add this line for midnight daily rotation
0 0 * * * /path/to/zero_trust/scripts/rotate_vault_audit.sh >> /var/log/vault-rotate.log 2>&1
```

Cron syntax: `minute hour day-of-month month day-of-week command`

| Field | Value | Meaning |
|-------|-------|---------|
| `0` | minute | At minute 0 |
| `0` | hour | At midnight (00:00) |
| `*` | day | Every day of the month |
| `*` | month | Every month |
| `*` | weekday | Every day of the week |

The `>> /var/log/vault-rotate.log 2>&1` part appends both stdout and stderr to a separate log file so you can audit the rotation itself.

### Verifying cron is working

After setting up the cron job, check that it ran:

```bash
# Check the rotation log
tail -20 /var/log/vault-rotate.log

# Check the audit directory for new archives
ls -lh vault/audit/
```

---

## Viewing archived logs

Archived logs are plain files — the same tools work on them as on the live log.

```bash
# Read a specific archive with audit_log.sh's jq formatting
cat vault/audit/vault-audit.20260403-201658.log \
  | jq '{time, type, op: .request.operation, path: .request.path, entity: .auth.display_name}'

# Count events by path in an archive
cat vault/audit/vault-audit.20260403-201658.log \
  | jq -r '.request.path' \
  | sort | uniq -c | sort -rn

# Search across all archives and the live log
cat vault/audit/vault-audit*.log \
  | jq 'select(.request.path | startswith("database/creds/"))'
```

---

## What happens if rotation is skipped

If the audit log is never rotated and the disk fills:

1. Vault cannot write a new audit entry
2. Vault treats this as a critical failure
3. **Vault stops serving all requests** — every API call returns an error
4. The backend cannot fetch credentials
5. The entire application goes down

The only recovery is to free disk space (delete old archives, clear other data) and let Vault resume. Vault does not require a restart — once disk space is available, it continues writing and serving requests automatically.

This is by design: Vault would rather be unavailable than silently operate without an audit trail.

---

## Manual rotation (without the script)

If you need to rotate manually without running the script:

```bash
# 1. Move the log (inside the container)
docker exec zero_trust_vault mv \
  /vault/audit/vault-audit.log \
  /vault/audit/vault-audit.$(date +%Y%m%d-%H%M%S).log

# 2. Signal Vault to reopen
docker exec zero_trust_vault sh -c 'kill -HUP $(pgrep -x vault)'

# 3. Verify a new log was created
docker exec zero_trust_vault ls -lh /vault/audit/
```

---

## Prerequisites

| Requirement | Why |
|-------------|-----|
| `docker` | Runs commands inside the Vault container |
| Vault container running | The process must be alive to receive SIGHUP |
| Phase 06 of `setup_vault.sh` complete | Audit logging must be enabled and the log file must exist |

---

## Troubleshooting

**`container 'zero_trust_vault' is not running`**
Start and unseal Vault before rotating:
```bash
docker compose up -d vault
./scripts/unseal_vault.sh
```

**`No audit file found — nothing to rotate`**
The audit file does not exist yet. This happens if audit logging was never enabled (run `setup_vault.sh --phase 06`) or if the file was already moved by a previous rotation and Vault did not yet create a new one.

**Vault still not creating a new log after SIGHUP**
Check Vault's logs for errors:
```bash
docker logs zero_trust_vault | tail -20
```
If the audit directory has a permissions problem, Vault will log the error there. The volume-mounted directory must be writable by the Vault process.

**Old archives not being pruned**
Check that the archive filenames match the pattern `vault-audit.*.log`. If rotation produced differently named files (e.g. from a manual rotation), the glob `vault-audit.*.log` will not match them and they will accumulate outside the `--keep` count.

**Checking disk usage in the audit volume:**
```bash
docker exec zero_trust_vault sh -c 'du -sh /vault/audit/*'
```
