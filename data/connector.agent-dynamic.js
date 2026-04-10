/**
 * connector.js — Vault credential provider
 *
 * This file is volume-mounted into the container so you can swap it out
 * without rebuilding the image. Nodemon will hot-reload the backend
 * automatically when you save changes here.
 *
 * Phase 1: reads static credentials from Vault KV v2
 *   → set VAULT_MODE=kv (or leave unset)
 *
 * Phase 2 (current): dynamic credentials from Vault database secrets engine
 *   → set VAULT_MODE=dynamic
 *
 * Vault setup for dynamic mode:
 *   vault secrets enable database
 *   vault write database/config/postgres \
 *     plugin_name=postgresql-database-plugin \
 *     allowed_roles="app-role" \
 *     connection_url="postgresql://{{username}}:{{password}}@localhost:5432/appdb?sslmode=disable" \
 *     username="appuser" password="apppassword"
 *   vault write database/roles/app-role \
 *     db_name=postgres \
 *     creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\"; GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\";" \
 *     default_ttl="1h" max_ttl="24h"
 */

const log = require('./logger');

const VAULT_ADDR    = process.env.VAULT_ADDR     || 'http://vault:8200';
const VAULT_TOKEN   = process.env.VAULT_TOKEN;
const VAULT_MODE    = process.env.VAULT_MODE      || 'dynamic';
const VAULT_KV_PATH = process.env.VAULT_KV_PATH   || 'secret/data/postgres';
const VAULT_DB_ROLE = process.env.VAULT_DB_ROLE   || 'app-role';

if (!VAULT_TOKEN) throw new Error('VAULT_TOKEN is not set');

// ---------------------------------------------------------------------------
// Phase 1 — static credentials from KV v2
// ---------------------------------------------------------------------------
async function getKvCredentials() {
  const res = await fetch(`${VAULT_ADDR}/v1/${VAULT_KV_PATH}`, {
    headers: { 'X-Vault-Token': VAULT_TOKEN },
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Vault KV responded ${res.status}: ${body}`);
  }

  const json = await res.json();
  const secret = json.data?.data;
  if (!secret) throw new Error(`No data found at ${VAULT_KV_PATH}`);

  return {
    host:     secret.host     || 'db',
    port:     Number(secret.port) || 5432,
    database: secret.database || 'appdb',
    user:     secret.username,
    password: secret.password,
    source:   'vault-kv',
    path:     VAULT_KV_PATH,
  };
}

// ---------------------------------------------------------------------------
// Phase 2 — dynamic credentials from database secrets engine
// ---------------------------------------------------------------------------

// Cache: reuse credentials until 75% of TTL has elapsed
const RENEWAL_THRESHOLD = 0.75;
let cachedCreds   = null;
let cacheExpiresAt = 0;

async function getDynamicCredentials() {
  const now = Date.now();

  if (cachedCreds && now < cacheExpiresAt) {
    return cachedCreds;
  }

  const res = await fetch(`${VAULT_ADDR}/v1/database/creds/${VAULT_DB_ROLE}`, {
    headers: { 'X-Vault-Token': VAULT_TOKEN },
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Vault dynamic creds responded ${res.status}: ${body}`);
  }

  const json = await res.json();
  const { username, password } = json.data;
  const lease_duration = json.lease_duration;

  log.info('Dynamic credentials issued', { user: username, ttl: lease_duration });

  cachedCreds    = {
    host:     'db',
    port:     5432,
    database: 'appdb',
    user:     username,
    password: password,
    source:   'vault-dynamic-agent',
    path:     `database/creds/${VAULT_DB_ROLE}`,
    ttl:      lease_duration,
    issuedAt: now,
    expiresAt: now + lease_duration * 1000,
  };
  cacheExpiresAt = now + Math.floor(lease_duration * RENEWAL_THRESHOLD * 1000);

  return cachedCreds;
}

// ---------------------------------------------------------------------------
// Exported function — called by server.js
// ---------------------------------------------------------------------------
async function getCredentials() {
  if (VAULT_MODE === 'kv') {
    return getKvCredentials();
  }
  return getDynamicCredentials();
}

// ---------------------------------------------------------------------------
// start() — backward-compat alias used by pool-manager.initialize()
// Connectors that support startAutoRenewal() use that path.
// This connector manages its own caching internally, so start() is a no-op
// that simply pre-warms the cache by fetching initial credentials.
// ---------------------------------------------------------------------------
async function start() {
  const creds = await getCredentials();
  log.info('Connector started — Vault Agent file-watch mode', { user: creds.user, source: creds.source, file: process.env.VAULT_AGENT_CREDS_FILE || 'direct-vault-api' });
  return creds;
}

module.exports = { getCredentials, start, MODE: "vault" };