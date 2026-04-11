#!/usr/bin/env bash
set -euo pipefail

# ─── Defaults (overridable via env vars) ──────────────────────────────────────
KEYCLOAK_URL="${KC_URL:-http://localhost:8080}"
ADMIN_USER="${KC_ADMIN_USER:-admin}"
ADMIN_PASS="${KC_ADMIN_PASS:-admin}"
KEYCLOAK_CONTAINER="${KC_CONTAINER:-zero_trust_keycloak}"
runtime="${CONTAINER_RUNTIME:-docker}"
TARGET_REALM="zero-trust"
PROVIDER_NAME="openldap"
FRONTEND_CLIENT_ID="zero-trust-app"
BACKEND_CLIENT_ID="backend"
REALM_ROLES=(admin support viewer)

# ─── Helpers ──────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Sets up Keycloak for the Zero Trust workshop. Idempotent.

OPTIONS:
  -u, --url URL           Keycloak base URL
  -U, --admin-user USER   Admin username
  -P, --admin-pass PASS   Admin password
  -c, --container NAME    Container name
  -r, --runtime RUNTIME   Container runtime: docker or podman (default: docker)
  -h, --help              Show this help

EOF
  exit 0
}

log()  { echo; echo "[KC] $*"; }
ok()   { echo "     ✓ $*"; }
skip() { echo "     – $* (already exists, skipping)"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

kcadm() { "${runtime}" exec "${KEYCLOAK_CONTAINER}" /opt/keycloak/bin/kcadm.sh "$@"; }

ensure_client() {
  local client_id="$1"
  local client_name="$2"
  local public_client="$3"
  local standard_flow="$4"
  local direct_access_grants="$5"
  local client_authenticator_type="${6:-}"
  local redirect_uris="${7:-}"
  local web_origins="${8:-}"
  local attributes="${9:-}"

  log "Ensuring OIDC client '${client_id}' exists..."

  local existing_client_id
  existing_client_id=$(kcadm get clients -r "${TARGET_REALM}" --fields clientId,id 2>/dev/null \
    | jq -er ".[] | select(.clientId==\"${client_id}\") | .id" || echo "")

  if [ -n "${existing_client_id}" ]; then
    skip "Client '${client_id}'"
    kcadm update "clients/${existing_client_id}" -r "${TARGET_REALM}" \
      -s clientId="${client_id}" \
      -s name="${client_name}" \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient="${public_client}" \
      -s standardFlowEnabled="${standard_flow}" \
      -s directAccessGrantsEnabled="${direct_access_grants}"
  else
    kcadm create clients -r "${TARGET_REALM}" \
      -s clientId="${client_id}" \
      -s name="${client_name}" \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient="${public_client}" \
      -s standardFlowEnabled="${standard_flow}" \
      -s directAccessGrantsEnabled="${direct_access_grants}"
    ok "Client '${client_id}' created"

    existing_client_id=$(kcadm get clients -r "${TARGET_REALM}" --fields clientId,id 2>/dev/null \
      | jq -er ".[] | select(.clientId==\"${client_id}\") | .id" || echo "")
  fi

  if [ -n "${client_authenticator_type}" ]; then
    kcadm update "clients/${existing_client_id}" -r "${TARGET_REALM}" \
      -s "clientAuthenticatorType=${client_authenticator_type}"
  fi

  if [ -n "${redirect_uris}" ]; then
    kcadm update "clients/${existing_client_id}" -r "${TARGET_REALM}" \
      -s "redirectUris=${redirect_uris}"
  fi

  if [ -n "${web_origins}" ]; then
    kcadm update "clients/${existing_client_id}" -r "${TARGET_REALM}" \
      -s "webOrigins=${web_origins}"
  fi

  if [ -n "${attributes}" ]; then
    kcadm update "clients/${existing_client_id}" -r "${TARGET_REALM}" \
      -s "attributes=${attributes}"
  fi
}

get_client_uuid() {
  local client_id="$1"
  kcadm get clients -r "${TARGET_REALM}" --fields clientId,id 2>/dev/null \
    | jq -er ".[] | select(.clientId==\"${client_id}\") | .id"
}

get_client_secret() {
  local client_id="$1"
  local client_uuid
  client_uuid=$(get_client_uuid "${client_id}")
  kcadm get "clients/${client_uuid}/client-secret" -r "${TARGET_REALM}" 2>/dev/null \
    | jq -er '.value'
}

ensure_realm_role() {
  local role_name="$1"

  log "Ensuring realm role '${role_name}' exists..."
  if kcadm get "roles/${role_name}" -r "${TARGET_REALM}" >/dev/null 2>&1; then
    skip "Realm role '${role_name}'"
  else
    kcadm create "roles" -r "${TARGET_REALM}" \
      -s name="${role_name}" \
      -s "description=Workshop role ${role_name}"
    ok "Realm role '${role_name}' created"
  fi
}

ensure_group_has_role() {
  local group_name="$1"
  local role_name="$2"

  log "Ensuring group '${group_name}' has realm role '${role_name}'..."

  local group_id
  group_id=$(kcadm get groups -r "${TARGET_REALM}" 2>/dev/null \
    | jq -er ".[] | select(.name==\"${group_name}\") | .id" || echo "")

  if [ -z "${group_id}" ]; then
    fail "Expected LDAP-synced Keycloak group '${group_name}' to exist after sync"
  fi

  if kcadm get "groups/${group_id}/role-mappings/realm" -r "${TARGET_REALM}" 2>/dev/null \
    | jq -e ".[] | select(.name==\"${role_name}\")" >/dev/null; then
    skip "Group '${group_name}' already mapped to role '${role_name}'"
    return
  fi

  kcadm add-roles -r "${TARGET_REALM}" --gid "${group_id}" --rolename "${role_name}"
  ok "Mapped group '${group_name}' to role '${role_name}'"
}

# ─── Arg parsing ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--url)          KEYCLOAK_URL="$2"; shift 2 ;;
    -U|--admin-user)   ADMIN_USER="$2";   shift 2 ;;
    -P|--admin-pass)   ADMIN_PASS="$2";   shift 2 ;;
    -c|--container)    KEYCLOAK_CONTAINER="$2"; shift 2 ;;
    -r|--runtime)      runtime="$2";            shift 2 ;;
    -h|--help)         usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# ─── Prerequisites ────────────────────────────────────────────────────────────
case "${runtime}" in
  docker|podman) ;;
  *) fail "Unsupported runtime '${runtime}'. Use docker or podman." ;;
esac

require_cmd "${runtime}"
require_cmd jq

"${runtime}" inspect "${KEYCLOAK_CONTAINER}" >/dev/null 2>&1 \
  || fail "Container '${KEYCLOAK_CONTAINER}' is not running. Start the stack first."

# Wait for Keycloak to respond
log "Waiting for Keycloak at ${KEYCLOAK_URL}..."
for i in {1..15}; do
  if curl -s -o /dev/null "${KEYCLOAK_URL}/auth"; then
    ok "Keycloak is reachable"
    break
  fi
  sleep 2
done

# ─── Step 1: Authenticate ─────────────────────────────────────────────────────
log "Authenticating as '${ADMIN_USER}'..."
kcadm config credentials \
  --server  "${KEYCLOAK_URL}" \
  --realm   master \
  --user    "${ADMIN_USER}" \
  --password "${ADMIN_PASS}"
ok "Authenticated"

# ─── Step 2: Create realm ─────────────────────────────────────────────────────
log "Ensuring realm '${TARGET_REALM}' exists..."
if kcadm get "realms/${TARGET_REALM}" >/dev/null 2>&1; then
  skip "Realm '${TARGET_REALM}'"
else
  kcadm create realms \
    -s realm="${TARGET_REALM}" \
    -s enabled=true \
    -s displayName="Zero Trust Workshop" \
    -s registrationAllowed=false \
    -s loginWithEmailAllowed=true \
    -s sslRequired=external
  ok "Realm '${TARGET_REALM}' created"
fi

# ─── Step 3: Resolve realm UUID ───────────────────────────────────────────────
REALM_ID=$(kcadm get "realms/${TARGET_REALM}" --fields id --format csv --noquotes)
log "Realm UUID: ${REALM_ID}"

# ─── Step 4: LDAP provider ────────────────────────────────────────────────────
log "Ensuring LDAP provider '${PROVIDER_NAME}' exists..."
PROVIDER_ID=$(kcadm get components -r "${TARGET_REALM}" 2>/dev/null \
  | jq -er ".[] | select(.name==\"${PROVIDER_NAME}\" and .providerType==\"org.keycloak.storage.UserStorageProvider\") | .id" || echo "")

if [ -n "$PROVIDER_ID" ]; then
  skip "LDAP provider '${PROVIDER_NAME}' (id: ${PROVIDER_ID})"
else
  PROVIDER_ID=$(kcadm create components -r "${TARGET_REALM}" \
    -s name="${PROVIDER_NAME}" \
    -s providerId=ldap \
    -s providerType=org.keycloak.storage.UserStorageProvider \
    -s parentId="${REALM_ID}" \
    -s 'config.enabled=["true"]' \
    -s 'config.priority=["0"]' \
    -s 'config.editMode=["READ_ONLY"]' \
    -s 'config.syncRegistrations=["false"]' \
    -s 'config.importEnabled=["true"]' \
    -s 'config.vendor=["other"]' \
    -s 'config.usernameLDAPAttribute=["uid"]' \
    -s 'config.rdnLDAPAttribute=["uid"]' \
    -s 'config.uuidLDAPAttribute=["entryUUID"]' \
    -s 'config.userObjectClasses=["person,organizationalPerson,inetOrgPerson"]' \
    -s 'config.connectionUrl=["ldap://openldap:389"]' \
    -s 'config.usersDn=["ou=people,dc=my,dc=org"]' \
    -s 'config.authType=["simple"]' \
    -s 'config.bindDn=["cn=admin,dc=my,dc=org"]' \
    -s 'config.bindCredential=["admin"]' \
    -s 'config.trustEmail=["true"]' \
    -s 'config.pagination=["true"]' \
    -s 'config.searchScope=["2"]' \
    -s 'config.batchSizeForSync=["1000"]' \
    -i)
  ok "LDAP provider created (id: ${PROVIDER_ID})"
fi

# ─── Step 5: LDAP group mapper ────────────────────────────────────────────────
GROUP_MAPPER_NAME="ldap-groups"
log "Ensuring LDAP group mapper '${GROUP_MAPPER_NAME}' exists..."
MAPPER_ID=$(kcadm get components -r "${TARGET_REALM}" 2>/dev/null \
  | jq -er ".[] | select(.name==\"${GROUP_MAPPER_NAME}\" and .providerType==\"org.keycloak.storage.ldap.mappers.LDAPStorageMapper\") | .id" || echo "")

if [ -n "${MAPPER_ID}" ]; then
  skip "Group mapper '${GROUP_MAPPER_NAME}'"
else
  kcadm create components -r "${TARGET_REALM}" \
    -s name="${GROUP_MAPPER_NAME}" \
    -s providerId=group-ldap-mapper \
    -s providerType=org.keycloak.storage.ldap.mappers.LDAPStorageMapper \
    -s parentId="${PROVIDER_ID}" \
    -s 'config."groups.dn"=["ou=groups,dc=my,dc=org"]' \
    -s 'config."group.name.ldap.attribute"=["cn"]' \
    -s 'config."group.object.classes"=["posixGroup"]' \
    -s 'config."membership.attribute.type"=["UID"]' \
    -s 'config."membership.ldap.attribute"=["memberUid"]' \
    -s 'config."membership.user.ldap.attribute"=["uid"]' \
    -s 'config.mode=["READ_ONLY"]' \
    -s 'config."user.roles.retrieve.strategy"=["LOAD_GROUPS_BY_MEMBER_ATTRIBUTE"]' \
    -s 'config."groups.path"=["/"]' \
    -s 'config."drop.non.existing.groups.during.sync"=["false"]'
  ok "Group mapper '${GROUP_MAPPER_NAME}' created"
fi

# ─── Step 6: OIDC clients ─────────────────────────────────────────────────────
ensure_client \
  "${FRONTEND_CLIENT_ID}" \
  "Zero Trust App" \
  true \
  true \
  true \
  "" \
  '["http://localhost:5173/*","http://localhost:3000/*"]' \
  '["http://localhost:5173","http://localhost:3000"]' \
  '{"pkce.code.challenge.method":"S256"}'

ensure_client \
  "${BACKEND_CLIENT_ID}" \
  "backend" \
  false \
  true \
  true \
  client-secret

BACKEND_CLIENT_SECRET=$(get_client_secret "${BACKEND_CLIENT_ID}")

# ─── Step 7: Realm roles ──────────────────────────────────────────────────────
for role_name in "${REALM_ROLES[@]}"; do
  ensure_realm_role "${role_name}"
done

# ─── Step 8: Full LDAP sync ───────────────────────────────────────────────────
log "Triggering full LDAP sync (users + groups)..."
kcadm create "user-storage/${PROVIDER_ID}/sync?action=triggerFullSync" -r "${TARGET_REALM}" -o
ok "Sync complete"

# ─── Step 9: Map groups to realm roles ────────────────────────────────────────
for role_name in "${REALM_ROLES[@]}"; do
  ensure_group_has_role "${role_name}" "${role_name}"
done

echo
echo "────────────────────────────────────────────────"
echo " Realm '${TARGET_REALM}' is ready."
echo " Frontend Client ID : ${FRONTEND_CLIENT_ID}"
echo " Backend Client ID  : ${BACKEND_CLIENT_ID}"
echo " Backend Secret     : ${BACKEND_CLIENT_SECRET}"
echo " Keycloak  : ${KEYCLOAK_URL}/realms/${TARGET_REALM}"
echo "────────────────────────────────────────────────"
