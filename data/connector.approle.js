/**
 * connector.js — AppRole credential provider
 *
 * Phase 4: authenticates to Vault using AppRole (role_id + secret_id),
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

const log = require('./logger');

const VAULT_ADDR      = process.env.VAULT_ADDR      || 'http://vault:8200';
const VAULT_ROLE_ID   = process.env.VAULT_ROLE_ID;
const VAULT_SECRET_ID = process.env.VAULT_SECRET_ID;
const VAULT_DB_ROLE   = process.env.VAULT_DB_ROLE   || 'app-role';

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
// Step 2 — use the token to fetch dynamic DB credentials (cached)
// ---------------------------------------------------------------------------

const RENEWAL_THRESHOLD = 0.75;
let cachedCreds    = null;
let cacheExpiresAt = 0;

async function getCredentials() {
  const now = Date.now();

  if (cachedCreds && now < cacheExpiresAt) {
    return cachedCreds;
  }

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

  log.info('Dynamic credentials issued', { user: username, ttl: lease_duration });

  cachedCreds = {
    host:      'db',
    port:      5432,
    database:  'appdb',
    user:      username,
    password,
    source:    'vault-approle',
    path:      `database/creds/${VAULT_DB_ROLE}`,
    ttl:       lease_duration,
    issuedAt:  now,
    expiresAt: now + lease_duration * 1000,
  };
  cacheExpiresAt = now + Math.floor(lease_duration * RENEWAL_THRESHOLD * 1000);

  return cachedCreds;
}

module.exports = { getCredentials, MODE: "vault" };
