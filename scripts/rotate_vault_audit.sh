#!/usr/bin/env bash
# rotate_vault_audit.sh — Rotate Vault audit log via SIGHUP
#
# Vault closes and reopens its audit file on SIGHUP, which is the correct
# way to rotate: move the current log, send SIGHUP, Vault creates a new one.
#
# Usage:
#   ./scripts/rotate_vault_audit.sh
#   ./scripts/rotate_vault_audit.sh --runtime podman
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
RUNTIME="auto"
EFFECTIVE_RUNTIME=""

detect_runtime() {
  if [[ -n "${CONTAINER_RUNTIME:-}" ]]; then
    case "${CONTAINER_RUNTIME}" in
      docker|podman)
        EFFECTIVE_RUNTIME="${CONTAINER_RUNTIME}"
        return 0
        ;;
    esac
  fi

  if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    EFFECTIVE_RUNTIME="podman"
    return 0
  fi

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    EFFECTIVE_RUNTIME="docker"
    return 0
  fi

  if command -v podman >/dev/null 2>&1; then
    EFFECTIVE_RUNTIME="podman"
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    EFFECTIVE_RUNTIME="docker"
    return 0
  fi

  echo "[rotate] ERROR: unable to detect a supported container runtime" >&2
  exit 1
}

resolve_runtime() {
  case "${RUNTIME}" in
    auto)
      detect_runtime
      ;;
    docker|podman)
      EFFECTIVE_RUNTIME="${RUNTIME}"
      ;;
    *)
      echo "[rotate] ERROR: unsupported runtime '${RUNTIME}'. Use docker, podman, or auto." >&2
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime) RUNTIME="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    --help)
      echo "Usage: $(basename "$0") [--runtime docker|podman|auto] [--keep N]"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

resolve_runtime

if ! command -v "${EFFECTIVE_RUNTIME}" >/dev/null 2>&1; then
  echo "[rotate] ERROR: ${EFFECTIVE_RUNTIME} CLI is not installed or not on PATH" >&2
  exit 1
fi

echo "[rotate] Starting Vault audit log rotation — $(date)"
echo "[rotate] Runtime   : ${EFFECTIVE_RUNTIME}"
echo "[rotate] Container : ${CONTAINER}"
echo "[rotate] Audit file: ${AUDIT_FILE}"
echo "[rotate] Keep      : ${KEEP} rotated files"

# ---------------------------------------------------------------------------
# Check container is running
# ---------------------------------------------------------------------------
if ! "${EFFECTIVE_RUNTIME}" inspect "${CONTAINER}" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
  echo "[rotate] ERROR: container '${CONTAINER}' is not running" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Move current log to timestamped file inside the container volume
# ---------------------------------------------------------------------------
ROTATED="${AUDIT_DIR}/vault-audit.${TIMESTAMP}.log"

if "${EFFECTIVE_RUNTIME}" exec "${CONTAINER}" test -f "${AUDIT_FILE}"; then
  "${EFFECTIVE_RUNTIME}" exec "${CONTAINER}" mv "${AUDIT_FILE}" "${ROTATED}"
  echo "[rotate] Moved to: ${ROTATED}"
else
  echo "[rotate] No audit file found — nothing to rotate"
  exit 0
fi

# ---------------------------------------------------------------------------
# Send SIGHUP — Vault reopens the audit file at the original path
# ---------------------------------------------------------------------------
"${EFFECTIVE_RUNTIME}" exec "${CONTAINER}" sh -c "kill -HUP \$(pgrep -x vault)"
echo "[rotate] SIGHUP sent — Vault will create a new ${AUDIT_FILE}"

# ---------------------------------------------------------------------------
# Prune old rotated files — keep the N most recent
# ---------------------------------------------------------------------------
ROTATED_COUNT=$("${EFFECTIVE_RUNTIME}" exec "${CONTAINER}" sh -c \
  "ls -1 ${AUDIT_DIR}/vault-audit.*.log 2>/dev/null | wc -l" | tr -d '[:space:]')

if [[ "${ROTATED_COUNT}" -gt "${KEEP}" ]]; then
  EXCESS=$(( ROTATED_COUNT - KEEP ))
  echo "[rotate] Pruning ${EXCESS} old file(s) (keeping ${KEEP})..."
  "${EFFECTIVE_RUNTIME}" exec "${CONTAINER}" sh -c \
    "ls -1t ${AUDIT_DIR}/vault-audit.*.log | tail -n ${EXCESS} | xargs rm -f"
fi

echo "[rotate] Done — $(date)"
