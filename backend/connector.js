/**
 * connector.js — AppRole + Dynamic credential provider with rotation support
 *
 * Authenticates to Vault using AppRole (role_id + secret_id), caches the
 * scoped Vault token, fetches dynamic PostgreSQL credentials, and manages
 * proactive renewal before lease expiry.
 *
 * Two layers of short-lived secrets:
 *   1. AppRole → short-lived Vault token (cached, renewed at 75% TTL)
 *   2. Vault token → dynamic DB credentials (renewed at 75% TTL)
 *
 * Rotation lifecycle:
 *   1. startAutoRenewal() kicks off the proactive timer
 *   2. At 75% of DB credential TTL, new credentials are fetched
 *   3. All registered onRotation() callbacks fire with fresh credentials
 *   4. If proactive renewal fails, it retries with backoff
 *   5. forceRotation() is available for reactive fallback from pool-manager
 *
 * Required environment variables:
 *   VAULT_ADDR      — Vault server address (default: http://vault:8200)
 *   VAULT_ROLE_ID   — AppRole role_id
 *   VAULT_SECRET_ID — AppRole secret_id
 *   VAULT_DB_ROLE   — database role name (default: app-role)
 *   VAULT_DB_HOST   — PostgreSQL host as seen by the app (default: db)
 *   VAULT_DB_PORT   — PostgreSQL port (default: 5432)
 *   VAULT_DB_NAME   — PostgreSQL database name (default: appdb)
 */

"use strict";

const VAULT_ADDR      = process.env.VAULT_ADDR      || "http://vault:8200";
const VAULT_ROLE_ID   = process.env.VAULT_ROLE_ID;
const VAULT_SECRET_ID = process.env.VAULT_SECRET_ID;
const VAULT_DB_ROLE   = process.env.VAULT_DB_ROLE   || "app-role";
const DB_HOST         = process.env.VAULT_DB_HOST   || "db";
const DB_PORT         = parseInt(process.env.VAULT_DB_PORT || "5432", 10);
const DB_NAME         = process.env.VAULT_DB_NAME   || "appdb";

const RENEWAL_THRESHOLD = 0.75;
const RETRY_DELAYS = [5, 10, 30, 60];

if (!VAULT_ROLE_ID)   throw new Error("VAULT_ROLE_ID is not set");
if (!VAULT_SECRET_ID) throw new Error("VAULT_SECRET_ID is not set");

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let cachedToken       = null;
let tokenExpiresAt    = 0;

let currentCredentials  = null;
let currentLeaseId      = null;
let credentialExpiresAt = 0;

let renewalTimer = null;
let running      = false;

const rotationListeners = [];

// ---------------------------------------------------------------------------
// Event registration
// ---------------------------------------------------------------------------

function onRotation(callback) {
  if (typeof callback !== "function") throw new TypeError("onRotation expects a function");
  rotationListeners.push(callback);
}

function emitRotation(credentials) {
  for (const listener of rotationListeners) {
    try { listener(credentials); }
    catch (err) { console.error("[connector] Rotation listener error:", err.message); }
  }
}

// ---------------------------------------------------------------------------
// Step 1 — AppRole login → scoped short-lived Vault token (cached)
// ---------------------------------------------------------------------------

async function getVaultToken() {
  const now = Date.now();
  if (cachedToken && tokenExpiresAt > now + 30000) return cachedToken;

  const res = await fetch(`${VAULT_ADDR}/v1/auth/approle/login`, {
    method:  "POST",
    headers: { "Content-Type": "application/json" },
    body:    JSON.stringify({ role_id: VAULT_ROLE_ID, secret_id: VAULT_SECRET_ID }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`AppRole login failed ${res.status}: ${body}`);
  }

  const json  = await res.json();
  const token = json.auth?.client_token;
  const ttl   = json.auth?.lease_duration;
  if (!token) throw new Error("AppRole login did not return a token");

  cachedToken    = token;
  tokenExpiresAt = now + (ttl * 1000);

  console.log(`[connector] AppRole login OK | token TTL: ${ttl}s`);
  return token;
}

// ---------------------------------------------------------------------------
// Step 2 — Fetch dynamic DB credentials
// ---------------------------------------------------------------------------

async function fetchCredentials() {
  const token = await getVaultToken();
  const path  = `database/creds/${VAULT_DB_ROLE}`;

  const res = await fetch(`${VAULT_ADDR}/v1/${path}`, {
    headers: { "X-Vault-Token": token },
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Dynamic creds request failed ${res.status}: ${body}`);
  }

  const json                   = await res.json();
  const { username, password } = json.data;
  const leaseId                = json.lease_id;
  const leaseDuration          = json.lease_duration;
  const now                    = Date.now();

  currentLeaseId      = leaseId;
  credentialExpiresAt = now + (leaseDuration * 1000);

  currentCredentials = {
    host:     DB_HOST,
    port:     DB_PORT,
    database: DB_NAME,
    user:     username,
    password: password,
    source:   "vault-approle-dynamic",
    path,
    ttl:      leaseDuration,
    leaseId,
    issuedAt:  now,
    expiresAt: credentialExpiresAt,
  };

  console.log(
    `[connector] Dynamic credentials issued | user: ${username} | TTL: ${leaseDuration}s | lease: ${leaseId}`
  );

  return currentCredentials;
}

// ---------------------------------------------------------------------------
// Public: getCredentials
// ---------------------------------------------------------------------------

async function getCredentials() {
  const now = Date.now();
  if (currentCredentials && credentialExpiresAt > now + 30000) return currentCredentials;
  return fetchCredentials();
}

// ---------------------------------------------------------------------------
// Public: forceRotation
// ---------------------------------------------------------------------------

async function forceRotation(reason) {
  console.log(`[connector] Forced rotation triggered | reason: ${reason}`);
  cachedToken    = null;
  tokenExpiresAt = 0;

  const creds = await fetchCredentials();
  emitRotation(creds);
  if (running) scheduleRenewal(creds.ttl);
  return creds;
}

// ---------------------------------------------------------------------------
// Proactive renewal timer
// ---------------------------------------------------------------------------

function scheduleRenewal(ttlSeconds) {
  if (renewalTimer) { clearTimeout(renewalTimer); renewalTimer = null; }

  const delayMs = Math.floor(ttlSeconds * RENEWAL_THRESHOLD * 1000);
  console.log(
    `[connector] Next renewal in ${Math.round(delayMs / 1000)}s ` +
    `(${Math.round(RENEWAL_THRESHOLD * 100)}% of ${ttlSeconds}s TTL)`
  );

  renewalTimer = setTimeout(() => performRenewal(0), delayMs);
  if (renewalTimer.unref) renewalTimer.unref();
}

async function performRenewal(retryIndex) {
  try {
    console.log("[connector] Proactive renewal starting...");
    const creds = await fetchCredentials();
    emitRotation(creds);
    scheduleRenewal(creds.ttl);
    console.log("[connector] Proactive renewal complete");
  } catch (err) {
    console.error(`[connector] Proactive renewal failed: ${err.message}`);
    const delay = RETRY_DELAYS[Math.min(retryIndex, RETRY_DELAYS.length - 1)];
    console.log(`[connector] Retrying in ${delay}s (attempt ${retryIndex + 1})`);
    renewalTimer = setTimeout(() => performRenewal(retryIndex + 1), delay * 1000);
    if (renewalTimer.unref) renewalTimer.unref();
  }
}

// ---------------------------------------------------------------------------
// Public: lifecycle management
// ---------------------------------------------------------------------------

async function startAutoRenewal() {
  running = true;
  const creds = await fetchCredentials();
  scheduleRenewal(creds.ttl);
  console.log("[connector] Auto-renewal started");
  return creds;
}

function stop() {
  running = false;
  if (renewalTimer) { clearTimeout(renewalTimer); renewalTimer = null; }
  console.log("[connector] Auto-renewal stopped");
}

function getLeaseInfo() {
  if (!currentCredentials) {
    return { status: "no-credentials", leaseId: null, remainingMs: 0, path: null };
  }
  const remainingMs = Math.max(0, credentialExpiresAt - Date.now());
  return {
    status:       remainingMs > 0 ? "active" : "expired",
    leaseId:      currentLeaseId,
    user:         currentCredentials.user,
    path:         currentCredentials.path,
    ttl:          currentCredentials.ttl,
    remainingMs,
    remainingSec: Math.round(remainingMs / 1000),
    issuedAt:     new Date(currentCredentials.issuedAt).toISOString(),
    expiresAt:    new Date(credentialExpiresAt).toISOString(),
  };
}

module.exports = {
  getCredentials,
  forceRotation,
  startAutoRenewal,
  stop,
  onRotation,
  getLeaseInfo,
};
