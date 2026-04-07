/**
 * connector.js — AppRole credential provider
 *
 * Phase 3: authenticates to Vault using AppRole (role_id + secret_id),
 * exchanges them for a short-lived Vault token, then fetches dynamic
 * PostgreSQL credentials from the database secrets engine.
 *
 * This is the recommended pattern for applications — no long-lived root
 * token required. The app only knows its role_id and secret_id.
 *
 * Required environment variables:
 *   VAULT_ADDR      — Vault server address (default: http://vault:8200)
 *   VAULT_ROLE_ID   — AppRole role_id
 *   VAULT_SECRET_ID — AppRole secret_id
 *   VAULT_DB_ROLE   — database role name (default: app-role)
 *
 * Vault setup (run setup_vault.sh — AppRole section handles this):
 *   vault auth enable approle
 *   vault policy write app-policy ...
 *   vault write auth/approle/role/zero-trust-app token_policies="app-policy" ...
 */

const VAULT_ADDR    = process.env.VAULT_ADDR      || 'http://vault:8200';
const VAULT_ROLE_ID = process.env.VAULT_ROLE_ID;
const VAULT_SECRET_ID = process.env.VAULT_SECRET_ID;
const VAULT_DB_ROLE = process.env.VAULT_DB_ROLE   || 'app-role';

if (!VAULT_ROLE_ID)   throw new Error('VAULT_ROLE_ID is not set');
if (!VAULT_SECRET_ID) throw new Error('VAULT_SECRET_ID is not set');

// ---------------------------------------------------------------------------
// Step 1 — AppRole login → short-lived Vault token
// ---------------------------------------------------------------------------
async function getVaultToken() {
  const res = await fetch(`${VAULT_ADDR}/v1/auth/approle/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      role_id:   VAULT_ROLE_ID,
      secret_id: VAULT_SECRET_ID,
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`AppRole login failed ${res.status}: ${body}`);
  }

  const json = await res.json();
  const token = json.auth?.client_token;
  const ttl   = json.auth?.lease_duration;

  if (!token) throw new Error('AppRole login did not return a token');

  console.log(`[connector] AppRole login successful — token TTL: ${ttl}s`);
  return token;
}

// ---------------------------------------------------------------------------
// Step 2 — use the token to fetch dynamic DB credentials
// ---------------------------------------------------------------------------
async function getCredentials() {
  const token = await getVaultToken();

  const res = await fetch(`${VAULT_ADDR}/v1/database/creds/${VAULT_DB_ROLE}`, {
    headers: { 'X-Vault-Token': token },
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Dynamic creds request failed ${res.status}: ${body}`);
  }

  const json = await res.json();
  const { username, password } = json.data;
  const lease_duration = json.lease_duration;

  console.log(`[connector] Dynamic credentials issued — user: ${username}, TTL: ${lease_duration}s`);

  return {
    host:     'db',
    port:     5432,
    database: 'appdb',
    user:     username,
    password: password,
    source:   'vault-approle',
    path:     `database/creds/${VAULT_DB_ROLE}`,
    ttl:      lease_duration,
  };
}

module.exports = { getCredentials };
