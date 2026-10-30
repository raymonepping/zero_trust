/**
 * connector.js — AppRole credential provider
 *
 * Phase 4: authenticates to Vault using AppRole (role_id + secret_id),
 * exchanges them for a short-lived Vault token, then reads static
 * PostgreSQL credentials from KV v2.
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

const log = require('./logger');

const VAULT_ADDR      = process.env.VAULT_ADDR      || 'http://vault:8200';
const VAULT_ROLE_ID   = process.env.VAULT_ROLE_ID;
const VAULT_SECRET_ID = process.env.VAULT_SECRET_ID;

if (!VAULT_ROLE_ID)   throw new Error('VAULT_ROLE_ID is not set');
if (!VAULT_SECRET_ID) throw new Error('VAULT_SECRET_ID is not set');

// ---------------------------------------------------------------------------
// Step 1 — AppRole login → short-lived Vault token (cached)
// ---------------------------------------------------------------------------

let cachedToken      = null;
let tokenExpiresAt   = 0;

async function getVaultToken() {
  const now = Date.now();

  if (cachedToken && now < tokenExpiresAt) {
    return cachedToken;
  }

  const res = await fetch(`${VAULT_ADDR}/v1/auth/approle/login`, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ role_id: VAULT_ROLE_ID, secret_id: VAULT_SECRET_ID }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`AppRole login failed ${res.status}: ${body}`);
  }

  const json  = await res.json();
  const token = json.auth?.client_token;
  const ttl   = json.auth?.lease_duration;

  if (!token) throw new Error('AppRole login did not return a token');

  log.info('AppRole login successful', { ttl });

  cachedToken    = token;
  tokenExpiresAt = now + Math.floor(ttl * 0.75 * 1000);

  return token;
}

// ---------------------------------------------------------------------------
// Step 2 — read static KV values using the AppRole token.
// Dynamic database issuance is introduced separately in approle-dynamic.
async function getCredentials() {
  const token = await getVaultToken();
  const kvPath = process.env.VAULT_KV_PATH || 'secret/data/postgres';
  const response = await fetch(`${VAULT_ADDR}/v1/${kvPath}`, {
    headers: { 'X-Vault-Token': token },
  });
  if (!response.ok) throw new Error(`AppRole KV request failed ${response.status}`);
  const secret = (await response.json()).data?.data;
  if (!secret?.username || !secret?.password) throw new Error('Incomplete KV database credentials');
  return {
    host: secret.host || 'db', port: Number(secret.port || 5432),
    database: secret.database || 'appdb', user: secret.username,
    password: secret.password, source: 'vault-approle', path: kvPath,
  };
}
module.exports = { getCredentials, MODE: "vault" };
