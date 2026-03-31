#!/usr/bin/env bash
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_FILE="${SCRIPT_DIR}/../vault/init.txt"

export VAULT_ADDR

if [[ ! -f "${INIT_FILE}" ]]; then
  echo "ERROR: init.txt not found at ${INIT_FILE}" >&2
  exit 1
fi

# Parse unseal keys and root token from init.txt
mapfile -t UNSEAL_KEYS < <(grep "^Unseal Key" "${INIT_FILE}" | awk '{print $NF}')
ROOT_TOKEN=$(grep "^Initial Root Token" "${INIT_FILE}" | awk '{print $NF}')

if [[ ${#UNSEAL_KEYS[@]} -eq 0 ]]; then
  echo "ERROR: No unseal keys found in ${INIT_FILE}" >&2
  exit 1
fi

echo "==> Vault address: ${VAULT_ADDR}"

# Check current seal status
SEALED=$(vault status -format=json 2>/dev/null | grep '"sealed"' | awk -F: '{print $2}' | tr -d ' ,') || true

if [[ "${SEALED}" == "false" ]]; then
  echo "==> Vault is already unsealed."
  exit 0
fi

echo "==> Unsealing Vault (threshold: 3 of ${#UNSEAL_KEYS[@]} keys)..."

# Apply first 3 keys (default Shamir threshold)
for i in 0 1 2; do
  echo "    Applying key $((i + 1))..."
  vault operator unseal "${UNSEAL_KEYS[$i]}" > /dev/null
done

# Confirm
SEALED_AFTER=$(vault status -format=json 2>/dev/null | grep '"sealed"' | awk -F: '{print $2}' | tr -d ' ,') || true

if [[ "${SEALED_AFTER}" == "false" ]]; then
  echo "==> Vault is unsealed."
  echo "    Root token: ${ROOT_TOKEN}"
else
  echo "ERROR: Vault is still sealed after applying 3 keys." >&2
  exit 1
fi
