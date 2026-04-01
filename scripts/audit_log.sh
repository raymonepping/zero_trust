#!/usr/bin/env bash
# audit_log.sh — Tail and filter the Vault audit log
#
# Usage:
#   ./scripts/audit_log.sh                   # tail live (all events)
#   ./scripts/audit_log.sh --type request    # only request events
#   ./scripts/audit_log.sh --type response   # only response events
#   ./scripts/audit_log.sh --path auth/      # filter by path prefix
#   ./scripts/audit_log.sh --op read         # filter by operation
#   ./scripts/audit_log.sh --lines 50        # show last N lines then follow
#   ./scripts/audit_log.sh --no-follow       # print and exit (no tail)
#   ./scripts/audit_log.sh --help

set -euo pipefail

CONTAINER="${VAULT_CONTAINER:-zero_trust_vault}"
AUDIT_FILE="/vault/audit/vault-audit.log"

# Defaults
FILTER_TYPE=""
FILTER_PATH=""
FILTER_OP=""
LINES=0
FOLLOW=true

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)       FILTER_TYPE="$2";  shift 2 ;;
    --path)       FILTER_PATH="$2";  shift 2 ;;
    --op)         FILTER_OP="$2";    shift 2 ;;
    --lines)      LINES="$2";        shift 2 ;;
    --no-follow)  FOLLOW=false;      shift   ;;
    --help)
      echo "Usage: $(basename "$0") [options]"
      echo ""
      echo "Options:"
      echo "  --type <request|response>   Filter by event type"
      echo "  --path <prefix>             Filter by request path prefix (e.g. auth/, database/)"
      echo "  --op   <operation>          Filter by operation (read, write, delete, list)"
      echo "  --lines <N>                 Show last N lines before following (default: all)"
      echo "  --no-follow                 Print existing log and exit"
      echo "  --help                      Show this help"
      echo ""
      echo "Examples:"
      echo "  $(basename "$0") --type request --path database/"
      echo "  $(basename "$0") --op write --no-follow"
      echo "  $(basename "$0") --lines 20"
      exit 0
      ;;
    *) echo "Unknown option: $1 — run --help for usage" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Build jq filter
# ---------------------------------------------------------------------------
JQ_FILTER="."

if [[ -n "${FILTER_TYPE}" ]]; then
  JQ_FILTER+=" | select(.type == \"${FILTER_TYPE}\")"
fi

if [[ -n "${FILTER_PATH}" ]]; then
  JQ_FILTER+=" | select(.request.path | startswith(\"${FILTER_PATH}\"))"
fi

if [[ -n "${FILTER_OP}" ]]; then
  JQ_FILTER+=" | select(.request.operation == \"${FILTER_OP}\")"
fi

# Pretty-print: show time, type, operation, path, auth entity, result
JQ_FORMAT="{
  time:      .time,
  type:      .type,
  op:        .request.operation,
  path:      .request.path,
  entity:    (.auth.entity_id // .auth.display_name // \"(anonymous)\"),
  policy:    (.auth.policy_results.allowed // null),
  remote_ip: .request.remote_address,
  error:     (.error // null)
}"

FULL_FILTER="${JQ_FILTER} | ${JQ_FORMAT}"

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
if ! docker inspect "${CONTAINER}" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
  echo "ERROR: container '${CONTAINER}' is not running" >&2
  exit 1
fi

TAIL_ARGS=""
[[ "${LINES}" -gt 0 ]] && TAIL_ARGS="-n ${LINES}"

if [[ "${FOLLOW}" == "true" ]]; then
  echo "[audit] Streaming ${AUDIT_FILE} (Ctrl+C to stop)"
  [[ -n "${FILTER_TYPE}" ]] && echo "[audit] Filter: type=${FILTER_TYPE}"
  [[ -n "${FILTER_PATH}" ]] && echo "[audit] Filter: path=${FILTER_PATH}"
  [[ -n "${FILTER_OP}"   ]] && echo "[audit] Filter: op=${FILTER_OP}"
  echo ""
  docker exec "${CONTAINER}" tail -f ${TAIL_ARGS} "${AUDIT_FILE}" \
    | jq --unbuffered -c "${FULL_FILTER}" 2>/dev/null \
    | jq .
else
  docker exec "${CONTAINER}" tail ${TAIL_ARGS} "${AUDIT_FILE}" \
    | jq -c "${FULL_FILTER}" 2>/dev/null \
    | jq .
fi
