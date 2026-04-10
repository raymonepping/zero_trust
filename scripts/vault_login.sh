#!/usr/bin/env bash

usage() {
  cat <<'EOF'
Usage:
  source ./scripts/vault_login.sh
  eval "$("./scripts/vault_login.sh")"

This script reads Vault credentials from ./data/.vault.env, authenticates with
Vault using a username/password auth method, and sets or prints:
  VAULT_ADDR
  VAULT_NAMESPACE
  VAULT_TOKEN

Supported env vars in ./data/.vault.env:
  VAULT_AUTH_METHOD      ldap (default) or userpass
  VAULT_LOGIN_USERNAME   preferred username variable
  VAULT_LOGIN_PASSWORD   preferred password variable

Backwards-compatible fallback vars:
  USER
  PASSWORD

When sourced, it exports the variables directly into your current shell.
When executed, it prints export commands so you can use it with eval.
EOF
}

shell_escape() {
  printf '%q' "$1"
}

supports_color() {
  [[ -t 2 && -z "${NO_COLOR:-}" ]]
}

style() {
  local code="$1"
  shift
  if supports_color; then
    printf '\033[%sm%s\033[0m' "${code}" "$*"
  else
    printf '%s' "$*"
  fi
}

info() {
  printf '%s %s\n' "$(style '36' '==>')" "$*" >&2
}

success() {
  printf '%s %s\n' "$(style '32' 'OK ')" "$*" >&2
}

error() {
  printf '%s %s\n' "$(style '31' 'ERR')" "$*" >&2
}

is_sourced() {
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    [[ "${ZSH_EVAL_CONTEXT:-}" == *file* ]]
    return
  fi

  if [[ -n "${BASH_VERSION:-}" ]]; then
    [[ "${BASH_SOURCE[0]}" != "$0" ]]
    return
  fi

  return 1
}

finish() {
  local exit_code="$1"
  if is_sourced; then
    return "${exit_code}"
  fi
  exit "${exit_code}"
}

main() {
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    emulate -L zsh
    setopt errexit nounset pipefail
  else
    set -euo pipefail
  fi

  local script_source script_dir env_file
  local vault_login_user vault_login_password vault_login_namespace vault_login_addr
  local vault_auth_method
  local vault_token

  if [[ -n "${BASH_VERSION:-}" ]]; then
    script_source="${BASH_SOURCE[0]}"
  elif [[ -n "${ZSH_VERSION:-}" ]]; then
    script_source="${(%):-%x}"
  else
    script_source="$0"
  fi

  script_dir="$(cd "$(dirname "${script_source}")" && pwd)"
  env_file=""

  if [[ -f "${script_dir}/../data/.vault.env" ]]; then
    env_file="${script_dir}/../data/.vault.env"
  elif [[ -f "${PWD}/data/.vault.env" ]]; then
    env_file="${PWD}/data/.vault.env"
  fi

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    return 0
  fi

  if [[ -z "${env_file}" ]]; then
    error "Vault env file not found. Checked ${script_dir}/../data/.vault.env and ${PWD}/data/.vault.env"
    return 1
  fi

  if ! command -v vault >/dev/null 2>&1; then
    error "vault CLI is not installed or not on PATH."
    return 1
  fi

  # Load credentials and connection settings from the repo-local env file.
  set -a
  . "${env_file}"
  set +a

  vault_login_user="${USER:-}"
  vault_login_password="${PASSWORD:-}"
  vault_login_namespace="${VAULT_NAMESPACE:-}"
  vault_login_addr="${VAULT_ADDR:-}"
  vault_auth_method="${VAULT_AUTH_METHOD:-ldap}"

  if [[ -n "${VAULT_LOGIN_USERNAME:-}" ]]; then
    vault_login_user="${VAULT_LOGIN_USERNAME}"
  elif [[ -n "${VAULT_USERNAME:-}" ]]; then
    vault_login_user="${VAULT_USERNAME}"
  fi

  if [[ -n "${VAULT_LOGIN_PASSWORD:-}" ]]; then
    vault_login_password="${VAULT_LOGIN_PASSWORD}"
  elif [[ -n "${VAULT_PASSWORD:-}" ]]; then
    vault_login_password="${VAULT_PASSWORD}"
  fi

  if [[ -z "${vault_login_user}" || -z "${vault_login_password}" ]]; then
    error "Set VAULT_LOGIN_USERNAME and VAULT_LOGIN_PASSWORD in ${env_file} (USER/PASSWORD also supported for compatibility)"
    return 1
  fi

  if [[ -z "${vault_login_addr}" ]]; then
    error "VAULT_ADDR must be set in ${env_file}"
    return 1
  fi

  case "${vault_auth_method}" in
    ldap|userpass) ;;
    *)
      error "Unsupported VAULT_AUTH_METHOD '${vault_auth_method}'. Use ldap or userpass."
      return 1
      ;;
  esac

  info "Authenticating to Vault as ${vault_login_user} using ${vault_auth_method}"
  export VAULT_ADDR="${vault_login_addr}"

  if [[ -n "${vault_login_namespace}" ]]; then
    export VAULT_NAMESPACE="${vault_login_namespace}"
  else
    unset VAULT_NAMESPACE
  fi

  if ! vault_token="$(
    vault login \
      -token-only \
      -method="${vault_auth_method}" \
      username="${vault_login_user}" \
      password="${vault_login_password}"
  )"; then
    error "Vault ${vault_auth_method} login failed for user ${vault_login_user}"
    return 1
  fi

  if is_sourced; then
    export VAULT_TOKEN="${vault_token}"
    success "Vault authentication succeeded"
    info "Address: ${vault_login_addr}"
    if [[ -n "${vault_login_namespace}" ]]; then
      info "Namespace: ${vault_login_namespace}"
    fi
  else
    echo "export VAULT_ADDR=$(shell_escape "${vault_login_addr}")"
    echo "export VAULT_TOKEN=$(shell_escape "${vault_token}")"
    if [[ -n "${vault_login_namespace}" ]]; then
      echo "export VAULT_NAMESPACE=$(shell_escape "${vault_login_namespace}")"
    else
      echo "unset VAULT_NAMESPACE"
    fi
    success "Vault authentication succeeded"
  fi
}

main "$@"
finish $?
