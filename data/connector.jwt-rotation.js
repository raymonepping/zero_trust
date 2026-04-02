/**
 * connector.js — Keycloak JWT → Vault token → Dynamic DB credentials + rotation
 *
 * Authentication chain:
 *   1. Fetch a short-lived JWT from Keycloak
 *   2. Exchange it for a scoped Vault token via auth/jwt/login
 *   3. Use the Vault token to fetch dynamic PostgreSQL credentials
 *   4. Proactively renew credentials before expiry
 */

"use strict";

const log         = require("./logger");

const KEYCLOAK_ADDR = process.env.KEYCLOAK_ADDR || "http://keycloak:8080";
const KEYCLOAK_REALM = process.env.KEYCLOAK_REALM || "zero-trust";
const KEYCLOAK_CLIENT_ID = process.env.KEYCLOAK_CLIENT_ID || "backend";
const KEYCLOAK_CLIENT_SECRET = process.env.KEYCLOAK_CLIENT_SECRET;
const KEYCLOAK_USERNAME = process.env.KEYCLOAK_USERNAME;
const KEYCLOAK_PASSWORD = process.env.KEYCLOAK_PASSWORD;

const VAULT_ADDR = process.env.VAULT_ADDR || "http://vault:8200";
const VAULT_JWT_ROLE = process.env.VAULT_JWT_ROLE || "zero-trust-jwt-lab";
const VAULT_DB_ROLE = process.env.VAULT_DB_ROLE || "app-role";

const DB_HOST = process.env.VAULT_DB_HOST || "db";
const DB_PORT = parseInt(process.env.VAULT_DB_PORT || "5432", 10);
const DB_NAME = process.env.VAULT_DB_NAME || "appdb";

if (!KEYCLOAK_CLIENT_SECRET) throw new Error("KEYCLOAK_CLIENT_SECRET is not set");
if (!KEYCLOAK_USERNAME) throw new Error("KEYCLOAK_USERNAME is not set");
if (!KEYCLOAK_PASSWORD) throw new Error("KEYCLOAK_PASSWORD is not set");

const RENEWAL_THRESHOLD = 0.75;
const RETRY_DELAYS = [5, 10, 30, 60];

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let cachedVaultToken = null;
let vaultTokenExpires = 0;

let currentCredentials = null;
let currentLeaseId = null;
let credentialExpiresAt = 0;

let renewalTimer = null;
let running = false;

let rotationInProgress = null;
let lastRenewalError = null;   // set on proactive renewal failure, cleared on success

const rotationListeners = [];

// ---------------------------------------------------------------------------
// Event registration
// ---------------------------------------------------------------------------

function onRotation(callback) {
  if (typeof callback !== "function") {
    throw new TypeError("onRotation expects a function");
  }

  rotationListeners.push(callback);
}

function emitRotation(credentials) {
  for (const listener of rotationListeners) {
    try {
      listener(credentials);
    } catch (err) {
      log.error("Rotation listener error", {
        error: err.message,
      });
    }
  }
}

// ---------------------------------------------------------------------------
// Step 1 — Fetch JWT from Keycloak
// ---------------------------------------------------------------------------

async function fetchKeycloakJwt() {
  const url = `${KEYCLOAK_ADDR}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token`;

  const body = new URLSearchParams({
    grant_type: "password",
    client_id: KEYCLOAK_CLIENT_ID,
    client_secret: KEYCLOAK_CLIENT_SECRET,
    username: KEYCLOAK_USERNAME,
    password: KEYCLOAK_PASSWORD,
    scope: "openid",
  });

  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: body.toString(),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Keycloak token request failed ${res.status}: ${text}`);
  }

  const json = await res.json();

  if (!json.access_token) {
    throw new Error("Keycloak did not return an access_token");
  }

  log.info("Keycloak JWT obtained", {
    expires_in: json.expires_in,
  });

  return json.access_token;
}

// ---------------------------------------------------------------------------
// Step 2 — Exchange JWT for Vault token
// ---------------------------------------------------------------------------

async function getVaultToken() {
  const now = Date.now();

  const remaining = vaultTokenExpires - now;
  const safetyMargin = Math.max(30_000, Math.floor(remaining * 0.25));

  if (cachedVaultToken && vaultTokenExpires > now + safetyMargin) {
    log.debug("Using cached Vault token");
    return cachedVaultToken;
  }

  const jwt = await fetchKeycloakJwt();

  const res = await fetch(`${VAULT_ADDR}/v1/auth/jwt/login`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      role: VAULT_JWT_ROLE,
      jwt,
    }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Vault JWT login failed ${res.status}: ${text}`);
  }

  const json = await res.json();

  const token = json.auth?.client_token;
  const ttl = json.auth?.lease_duration;

  if (!token) {
    throw new Error("Vault JWT login did not return a token");
  }

  cachedVaultToken = token;
  vaultTokenExpires = now + ttl * 1000;

  log.info("Vault JWT login OK", {
    ttl,
    role: VAULT_JWT_ROLE,
  });

  return token;
}

// ---------------------------------------------------------------------------
// Step 3 — Fetch dynamic DB credentials
// ---------------------------------------------------------------------------

async function fetchCredentials() {
  const token = await getVaultToken();

  const path = `database/creds/${VAULT_DB_ROLE}`;

  const res = await fetch(`${VAULT_ADDR}/v1/${path}`, {
    headers: {
      "X-Vault-Token": token,
    },
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Dynamic creds request failed ${res.status}: ${text}`);
  }

  const json = await res.json();

  const { username, password } = json.data;
  const leaseId = json.lease_id;
  const leaseDuration = json.lease_duration;
  const now = Date.now();

  const previousLeaseId = currentLeaseId;
  currentLeaseId = leaseId;
  credentialExpiresAt = now + leaseDuration * 1000;

  currentCredentials = {
    host: DB_HOST,
    port: DB_PORT,
    database: DB_NAME,
    user: username,
    password,
    source: "vault-jwt-dynamic",
    path,
    ttl: leaseDuration,
    leaseId,
    issuedAt: now,
    expiresAt: credentialExpiresAt,
    previousLeaseId,
  };

  log.info("Dynamic credentials issued", {
    user: username,
    ttl: leaseDuration,
    lease_id: leaseId,
    role: VAULT_DB_ROLE,
  });

  return currentCredentials;
}

// ---------------------------------------------------------------------------
// Unified credential refresh lock
// ---------------------------------------------------------------------------

async function refreshCredentials(reason = "unknown") {
  if (rotationInProgress) {
    return rotationInProgress;
  }

  rotationInProgress = (async () => {
    const creds = await fetchCredentials();

    log.info("Credential refresh complete", {
      reason,
      user: creds.user,
      lease_id: creds.leaseId,
    });

    emitRotation(creds);

    if (running) {
      scheduleRenewal(creds.ttl);
    }

    return creds;
  })();

  try {
    return await rotationInProgress;
  } finally {
    rotationInProgress = null;
  }
}

// ---------------------------------------------------------------------------
// Public: getCredentials
// ---------------------------------------------------------------------------

async function getCredentials() {
  const now = Date.now();

  if (currentCredentials && credentialExpiresAt > now + 30_000) {
    return currentCredentials;
  }

  return refreshCredentials("cache-expired");
}

// ---------------------------------------------------------------------------
// Public: forceRotation
// ---------------------------------------------------------------------------

async function forceRotation(reason) {
  log.warn("Forced rotation triggered", {
    reason,
  });

  cachedVaultToken = null;
  vaultTokenExpires = 0;

  return refreshCredentials(reason);
}

// ---------------------------------------------------------------------------
// Proactive renewal timer
// ---------------------------------------------------------------------------

function scheduleRenewal(ttlSeconds) {
  if (renewalTimer) {
    clearTimeout(renewalTimer);
    renewalTimer = null;
  }

  const delayMs = Math.floor(ttlSeconds * RENEWAL_THRESHOLD * 1000);

  log.info("Next renewal scheduled", {
    delay_sec: Math.round(delayMs / 1000),
    threshold_pct: Math.round(RENEWAL_THRESHOLD * 100),
    ttl: ttlSeconds,
  });

  renewalTimer = setTimeout(() => performRenewal(0), delayMs);

  if (renewalTimer.unref) {
    renewalTimer.unref();
  }
}

async function performRenewal(retryIndex) {
  try {
    log.info("Proactive renewal starting");

    await refreshCredentials("proactive");

    lastRenewalError = null;
    log.info("Proactive renewal complete");
  } catch (err) {
    lastRenewalError = err.message;
    log.error("Proactive renewal failed", {
      error: err.message,
    });

    const delay =
      RETRY_DELAYS[Math.min(retryIndex, RETRY_DELAYS.length - 1)];

    log.warn("Renewal retry scheduled", {
      delay,
      attempt: retryIndex + 1,
    });

    renewalTimer = setTimeout(
      () => performRenewal(retryIndex + 1),
      delay * 1000
    );

    if (renewalTimer.unref) {
      renewalTimer.unref();
    }
  }
}

// ---------------------------------------------------------------------------
// Public lifecycle
// ---------------------------------------------------------------------------
async function revokeLease(leaseId) {
  if (!leaseId) return;

  const token = await getVaultToken();

  const res = await fetch(`${VAULT_ADDR}/v1/sys/leases/revoke`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Vault-Token": token,
    },
    body: JSON.stringify({
      lease_id: leaseId,
    }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Lease revoke failed ${res.status}: ${text}`);
  }

  log.info("Lease revoked", {
    lease_id: leaseId,
  });
}

async function lookupLease(leaseId) {
  if (!leaseId) return { exists: false, status: "missing", ttl: null };

  const token = await getVaultToken();

  const res = await fetch(`${VAULT_ADDR}/v1/sys/leases/lookup`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Vault-Token": token,
    },
    body: JSON.stringify({ lease_id: leaseId }),
  });

  if (res.status === 400 || res.status === 404) {
    return { exists: false, status: "revoked", ttl: null };
  }

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Lease lookup failed ${res.status}: ${text}`);
  }

  const json = await res.json();

  return { exists: true, status: "active", ttl: json.data?.ttl ?? null };
}

async function startAutoRenewal() {
  running = true;

  const creds = await refreshCredentials("initial");

  log.info("Auto-renewal started");

  return creds;
}

function stop() {
  running = false;

  if (renewalTimer) {
    clearTimeout(renewalTimer);
    renewalTimer = null;
  }

  log.info("Auto-renewal stopped");
}

// ---------------------------------------------------------------------------
// Lease info
// ---------------------------------------------------------------------------

function getLeaseInfo() {
  if (!currentCredentials) {
    return {
      status: "no-credentials",
      leaseId: null,
      remainingMs: 0,
      path: null,
    };
  }

  const remainingMs = Math.max(0, credentialExpiresAt - Date.now());

  return {
    leaseId: currentLeaseId,
    user: currentCredentials.user,
    path: currentCredentials.path,
    ttl: currentCredentials.ttl,
    remainingMs,
    remainingSec: Math.round(remainingMs / 1000),
    renewalError: lastRenewalError,
    issuedAt: new Date(currentCredentials.issuedAt).toISOString(),
    expiresAt: new Date(credentialExpiresAt).toISOString(),
  };
}

module.exports = {
  getCredentials,
  forceRotation,
  startAutoRenewal,
  stop,
  onRotation,
  getLeaseInfo,
  revokeLease,
  lookupLease,
};