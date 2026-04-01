#!/usr/bin/env bash
# rotate_vault_audit.sh — Rotate Vault audit log via SIGHUP
#
# Vault closes and reopens its audit file on SIGHUP, which is the correct
# way to rotate: move the current log, send SIGHUP, Vault creates a new one.
#
# Usage:
#   ./scripts/rotate_vault_audit.sh
#   ./scripts/rotate_vault_audit.sh --keep 14   # keep 14 rotated files (default: 7)
#
# Set up a cron job for daily rotation:
#   0 0 * * * /path/to/zero_trust/scripts/rotate_vault_audit.sh >> /var/log/vault-rotate.log 2>&1

set -euo pipefail

CONTAINER="${VAULT_CONTAINER:-zero_trust_vault}"
AUDIT_DIR="${AUDIT_DIR:-/vault/audit}"
AUDIT_FILE="${AUDIT_DIR}/vault-audit.log"
KEEP="${KEEP:-7}"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "[rotate] Starting Vault audit log rotation — $(date)"
echo "[rotate] Container : ${CONTAINER}"
echo "[rotate] Audit file: ${AUDIT_FILE}"
echo "[rotate] Keep      : ${KEEP} rotated files"

# ---------------------------------------------------------------------------
# Check container is running
# ---------------------------------------------------------------------------
if ! docker inspect "${CONTAINER}" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
  echo "[rotate] ERROR: container '${CONTAINER}' is not running" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Move current log to timestamped file inside the container volume
# ---------------------------------------------------------------------------
ROTATED="${AUDIT_DIR}/vault-audit.${TIMESTAMP}.log"

if docker exec "${CONTAINER}" test -f "${AUDIT_FILE}"; then
  docker exec "${CONTAINER}" mv "${AUDIT_FILE}" "${ROTATED}"
  echo "[rotate] Moved to: ${ROTATED}"
else
  echo "[rotate] No audit file found — nothing to rotate"
  exit 0
fi

# ---------------------------------------------------------------------------
# Send SIGHUP — Vault reopens the audit file at the original path
# ---------------------------------------------------------------------------
docker exec "${CONTAINER}" sh -c 'kill -HUP $(pgrep -x vault)'
echo "[rotate] SIGHUP sent — Vault will create a new ${AUDIT_FILE}"

# ---------------------------------------------------------------------------
# Prune old rotated files — keep the N most recent
# ---------------------------------------------------------------------------
ROTATED_COUNT=$(docker exec "${CONTAINER}" sh -c \
  "ls -1 ${AUDIT_DIR}/vault-audit.*.log 2>/dev/null | wc -l" | tr -d '[:space:]')

if [[ "${ROTATED_COUNT}" -gt "${KEEP}" ]]; then
  EXCESS=$(( ROTATED_COUNT - KEEP ))
  echo "[rotate] Pruning ${EXCESS} old file(s) (keeping ${KEEP})..."
  docker exec "${CONTAINER}" sh -c \
    "ls -1t ${AUDIT_DIR}/vault-audit.*.log | tail -n ${EXCESS} | xargs rm -f"
fi

echo "[rotate] Done — $(date)"
