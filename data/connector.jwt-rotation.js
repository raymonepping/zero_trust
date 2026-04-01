/**
 * connector.js — Keycloak JWT → Vault token → Dynamic DB credentials + rotation
 *
 * Authentication chain:
 *   1. Fetch a short-lived JWT from Keycloak (password grant or client_credentials)
 *   2. Exchange it for a scoped Vault token via auth/jwt/login
 *   3. Use the Vault token to fetch dynamic PostgreSQL credentials
 *   4. Proactively renew credentials at 75% of TTL
 *
 * Three layers of short-lived secrets:
 *   1. Keycloak → short-lived JWT (refreshed when near expiry)
 *   2. JWT → scoped Vault token (cached, renewed at 75% TTL)
 *   3. Vault token → dynamic DB credentials (renewed at 75% TTL)
 *
 * Required environment variables:
 *   KEYCLOAK_ADDR          — Keycloak address (default: http://keycloak:8080)
 *   KEYCLOAK_REALM         — Keycloak realm (default: zero-trust)
 *   KEYCLOAK_CLIENT_ID     — Client ID (default: backend)
 *   KEYCLOAK_CLIENT_SECRET — Client secret
 *   KEYCLOAK_USERNAME      — Username for password grant
 *   KEYCLOAK_PASSWORD      — Password for password grant
 *   VAULT_ADDR             — Vault server address (default: http://vault:8200)
 *   VAULT_JWT_ROLE         — Vault JWT role name (default: zero-trust-jwt-lab)
 *   VAULT_DB_ROLE          — Database role name (default: app-role)
 *   VAULT_DB_HOST          — PostgreSQL host (default: db)
 *   VAULT_DB_PORT          — PostgreSQL port (default: 5432)
 *   VAULT_DB_NAME          — PostgreSQL database name (default: appdb)
 */

"use strict";

const KEYCLOAK_ADDR          = process.env.KEYCLOAK_ADDR          || "http://keycloak:8080";
const KEYCLOAK_REALM         = process.env.KEYCLOAK_REALM         || "zero-trust";
const KEYCLOAK_CLIENT_ID     = process.env.KEYCLOAK_CLIENT_ID     || "backend";
const KEYCLOAK_CLIENT_SECRET = process.env.KEYCLOAK_CLIENT_SECRET;
const KEYCLOAK_USERNAME      = process.env.KEYCLOAK_USERNAME;
const KEYCLOAK_PASSWORD      = process.env.KEYCLOAK_PASSWORD;

const VAULT_ADDR    = process.env.VAULT_ADDR     || "http://vault:8200";
const VAULT_JWT_ROLE = process.env.VAULT_JWT_ROLE || "zero-trust-jwt-lab";
const VAULT_DB_ROLE = process.env.VAULT_DB_ROLE  || "app-role";
const DB_HOST       = process.env.VAULT_DB_HOST  || "db";
const DB_PORT       = parseInt(process.env.VAULT_DB_PORT || "5432", 10);
const DB_NAME       = process.env.VAULT_DB_NAME  || "appdb";

if (!KEYCLOAK_CLIENT_SECRET) throw new Error("KEYCLOAK_CLIENT_SECRET is not set");
if (!KEYCLOAK_USERNAME)      throw new Error("KEYCLOAK_USERNAME is not set");
if (!KEYCLOAK_PASSWORD)      throw new Error("KEYCLOAK_PASSWORD is not set");

const RENEWAL_THRESHOLD = 0.75;
const RETRY_DELAYS      = [5, 10, 30, 60];

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let cachedVaultToken  = null;
let vaultTokenExpires = 0;

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
// Step 1 — Fetch JWT from Keycloak
// ---------------------------------------------------------------------------

async function fetchKeycloakJwt() {
  const url = `${KEYCLOAK_ADDR}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token`;

  const body = new URLSearchParams({
    grant_type:    "password",
    client_id:     KEYCLOAK_CLIENT_ID,
    client_secret: KEYCLOAK_CLIENT_SECRET,
    username:      KEYCLOAK_USERNAME,
    password:      KEYCLOAK_PASSWORD,
    scope:         "openid",
  });

  const res = await fetch(url, {
    method:  "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body:    body.toString(),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Keycloak token request failed ${res.status}: ${text}`);
  }

  const json = await res.json();
  if (!json.access_token) throw new Error("Keycloak did not return an access_token");

  console.log(`[connector] Keycloak JWT obtained | expires_in: ${json.expires_in}s`);
  return json.access_token;
}

// ---------------------------------------------------------------------------
// Step 2 — Exchange JWT for a scoped Vault token (cached)
// ---------------------------------------------------------------------------

async function getVaultToken() {
  const now = Date.now();
  if (cachedVaultToken && vaultTokenExpires > now + 30000) return cachedVaultToken;

  const jwt = await fetchKeycloakJwt();

  const res = await fetch(`${VAULT_ADDR}/v1/auth/jwt/login`, {
    method:  "POST",
    headers: { "Content-Type": "application/json" },
    body:    JSON.stringify({ role: VAULT_JWT_ROLE, jwt }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Vault JWT login failed ${res.status}: ${text}`);
  }

  const json  = await res.json();
  const token = json.auth?.client_token;
  const ttl   = json.auth?.lease_duration;
  if (!token) throw new Error("Vault JWT login did not return a token");

  cachedVaultToken  = token;
  vaultTokenExpires = now + (ttl * 1000);

  console.log(`[connector] Vault JWT login OK | token TTL: ${ttl}s`);
  return token;
}

// ---------------------------------------------------------------------------
// Step 3 — Fetch dynamic DB credentials
// ---------------------------------------------------------------------------

async function fetchCredentials() {
  const token = await getVaultToken();
  const path  = `database/creds/${VAULT_DB_ROLE}`;

  const res = await fetch(`${VAULT_ADDR}/v1/${path}`, {
    headers: { "X-Vault-Token": token },
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Dynamic creds request failed ${res.status}: ${text}`);
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
    source:   "vault-jwt-dynamic",
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
  cachedVaultToken  = null;
  vaultTokenExpires = 0;

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
