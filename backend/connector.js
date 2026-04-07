/**
 * connector.js — Mode-aware, role-scoped credential provider
 *
 * Mode detection at startup:
 *
 *   VAULT mode  (KEYCLOAK_CLIENT_SECRET + KEYCLOAK_USERNAME + KEYCLOAK_PASSWORD):
 *     Keycloak JWT → Vault JWT auth → role-scoped dynamic DB credentials,
 *     per-role proactive renewal, reactive rotation, lease revocation.
 *
 *   STATIC mode (DB_USER + DB_PASSWORD, no Keycloak vars):
 *     Returns .env credentials directly. No rotation, no role scoping,
 *     no renewal timers. Functional but without zero trust properties.
 *
 * Role-aware credential chain (vault mode):
 *   1. Fetch short-lived JWT from Keycloak (machine identity)
 *   2. Exchange JWT for scoped Vault token via auth/jwt/login
 *   3. Map userContext.role → Vault DB role via backend-owned mapping
 *   4. Fetch dynamic PostgreSQL credentials for that specific role
 *   5. Proactively renew per-role credentials before expiry
 */

"use strict";

const log = require("./logger");

// ---------------------------------------------------------------------------
// Common configuration
// ---------------------------------------------------------------------------

const DB_HOST = process.env.DB_HOST || process.env.VAULT_DB_HOST || "db";
const DB_PORT = parseInt(process.env.DB_PORT || process.env.VAULT_DB_PORT || "5432", 10);
const DB_NAME = process.env.DB_NAME || process.env.VAULT_DB_NAME || "appdb";

// ---------------------------------------------------------------------------
// Mode detection
// ---------------------------------------------------------------------------

const KEYCLOAK_CLIENT_SECRET = process.env.KEYCLOAK_CLIENT_SECRET;
const KEYCLOAK_USERNAME      = process.env.KEYCLOAK_USERNAME;
const KEYCLOAK_PASSWORD      = process.env.KEYCLOAK_PASSWORD;
const DB_USER                = process.env.DB_USER;
const DB_PASSWORD            = process.env.DB_PASSWORD;

const MODE = (KEYCLOAK_CLIENT_SECRET && KEYCLOAK_USERNAME && KEYCLOAK_PASSWORD)
  ? "vault"
  : "static";

if (MODE === "static" && (!DB_USER || !DB_PASSWORD)) {
  throw new Error(
    "Credential configuration missing. Provide either:\n" +
    "  Vault mode:  KEYCLOAK_CLIENT_SECRET + KEYCLOAK_USERNAME + KEYCLOAK_PASSWORD\n" +
    "  Static mode: DB_USER + DB_PASSWORD"
  );
}

log.info(`Connector mode: ${MODE}`);

// ---------------------------------------------------------------------------
// JWT role → Vault database role mapping (vault mode only)
//
// JWT claim names never flow directly into Vault API calls.
// All roles fall back to DEFAULT_DB_ROLE (app-role) unless overridden via env.
// ---------------------------------------------------------------------------

const DEFAULT_DB_ROLE = process.env.VAULT_DB_ROLE || "viewer-read";

const VAULT_ROLE_MAP = {
  viewer:  process.env.VAULT_DB_ROLE_VIEWER  || DEFAULT_DB_ROLE,
  support: process.env.VAULT_DB_ROLE_SUPPORT || DEFAULT_DB_ROLE,
  admin:   process.env.VAULT_DB_ROLE_ADMIN   || DEFAULT_DB_ROLE,
};

function resolveVaultRole(role) {
  // No role (anonymous / unauthenticated) — silently use least privilege
  if (!role) return VAULT_ROLE_MAP.viewer;

  const canonicalRoles = new Set([
    "viewer-read",
    "support-read",
    "admin-read",
  ]);

  if (canonicalRoles.has(role)) {
    return role;
  }

  const roleMap = {
    viewer:  "viewer-read",
    support: "support-read",
    admin:   "admin-read",
  };

  if (roleMap[role]) {
    return roleMap[role];
  }

  log.warn("Unknown JWT role, falling back to default", {
    role,
    fallback: DEFAULT_DB_ROLE,
  });

  return DEFAULT_DB_ROLE;
}

function getKnownRoles() {
  if (MODE === "static") return ["static"];
  // Deduplicate: in single-role setups all map to app-role → returns ["app-role"]
  return [...new Set(Object.values(VAULT_ROLE_MAP))];
}

// ---------------------------------------------------------------------------
// Shared event system
// ---------------------------------------------------------------------------

const rotationListeners = [];
let running = false;

function onRotation(callback) {
  if (typeof callback !== "function") {
    throw new TypeError("onRotation expects a function");
  }
  rotationListeners.push(callback);
}

function emitRotation(vaultRole, credentials) {
  for (const listener of rotationListeners) {
    try {
      listener(vaultRole, credentials);
    } catch (err) {
      log.error("Rotation listener error", { error: err.message });
    }
  }
}

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║  STATIC MODE                                                             ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

const staticCredentials = MODE === "static" ? {
  host:            DB_HOST,
  port:            DB_PORT,
  database:        DB_NAME,
  user:            DB_USER,
  password:        DB_PASSWORD,
  source:          "static-config",
  path:            ".env",
  vaultRole:       "static",
  ttl:             null,
  leaseId:         null,
  previousLeaseId: null,
  issuedAt:        Date.now(),
  expiresAt:       null,
  issuedFor:       "system",
} : null;

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║  VAULT MODE                                                              ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

const KEYCLOAK_ADDR      = process.env.KEYCLOAK_ADDR      || "http://keycloak:8080";
const KEYCLOAK_REALM     = process.env.KEYCLOAK_REALM     || "zero-trust";
const KEYCLOAK_CLIENT_ID = process.env.KEYCLOAK_CLIENT_ID || "backend";

const VAULT_ADDR     = process.env.VAULT_ADDR     || "http://vault:8200";
const VAULT_JWT_ROLE = process.env.VAULT_JWT_ROLE || "zero-trust-jwt-lab";

const RENEWAL_THRESHOLD = 0.75;
const RETRY_DELAYS      = [5, 10, 30, 60];

// Vault token cache — single machine identity, shared across all roles
let cachedVaultToken  = null;
let vaultTokenExpires = 0;

// Per-role credential state: Map<vaultRole, { credentials, leaseId, expiresAt, renewalTimer, rotationInProgress, lastRenewalError }>
const roleState = new Map();

function getRoleState(vaultRole) {
  if (!roleState.has(vaultRole)) {
    roleState.set(vaultRole, {
      credentials:        null,
      leaseId:            null,
      expiresAt:          0,
      renewalTimer:       null,
      rotationInProgress: null,
      lastRenewalError:   null,
    });
  }
  return roleState.get(vaultRole);
}

// ---------------------------------------------------------------------------
// Step 1 — Fetch JWT from Keycloak (machine identity)
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

  if (!json.access_token) {
    throw new Error("Keycloak did not return an access_token");
  }

  log.info("Keycloak JWT obtained", { expires_in: json.expires_in });
  return json.access_token;
}

// ---------------------------------------------------------------------------
// Step 2 — Exchange JWT for Vault token (cached, shared across roles)
// ---------------------------------------------------------------------------

async function getVaultToken() {
  const now          = Date.now();
  const remaining    = vaultTokenExpires - now;
  const safetyMargin = Math.max(30_000, Math.floor(remaining * 0.25));

  if (cachedVaultToken && vaultTokenExpires > now + safetyMargin) {
    log.debug("Using cached Vault token");
    return cachedVaultToken;
  }

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
  vaultTokenExpires = now + ttl * 1000;

  log.info("Vault JWT login OK", { ttl, role: VAULT_JWT_ROLE });
  return token;
}

// ---------------------------------------------------------------------------
// Step 3 — Fetch dynamic DB credentials for a specific Vault role
// ---------------------------------------------------------------------------

async function fetchCredentials(vaultRole, userContext) {
  const token = await getVaultToken();
  const path  = `database/creds/${vaultRole}`;

  const res = await fetch(`${VAULT_ADDR}/v1/${path}`, {
    headers: { "X-Vault-Token": token },
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Dynamic creds request failed for role "${vaultRole}" ${res.status}: ${text}`);
  }

  const json                   = await res.json();
  const { username, password } = json.data;
  const leaseId                = json.lease_id;
  const leaseDuration          = json.lease_duration;
  const now                    = Date.now();

  const state           = getRoleState(vaultRole);
  const previousLeaseId = state.leaseId;

  const credentials = {
    host:            DB_HOST,
    port:            DB_PORT,
    database:        DB_NAME,
    user:            username,
    password,
    source:          "vault-jwt-dynamic",
    path,
    vaultRole,
    ttl:             leaseDuration,
    leaseId,
    previousLeaseId,
    issuedAt:        now,
    expiresAt:       now + leaseDuration * 1000,
    issuedFor:       userContext?.sub || "system",
  };

  state.credentials = credentials;
  state.leaseId     = leaseId;
  state.expiresAt   = credentials.expiresAt;

  log.info("Dynamic credentials issued", {
    role:     vaultRole,
    user:     username,
    ttl:      leaseDuration,
    lease_id: leaseId,
    for:      credentials.issuedFor,
  });

  return credentials;
}

// ---------------------------------------------------------------------------
// Unified per-role credential refresh lock
// ---------------------------------------------------------------------------

async function refreshCredentials(vaultRole, reason, userContext) {
  const state = getRoleState(vaultRole);

  if (state.rotationInProgress) {
    return state.rotationInProgress;
  }

  state.rotationInProgress = (async () => {
    const creds = await fetchCredentials(vaultRole, userContext);

    log.info("Credential refresh complete", {
      role:     vaultRole,
      reason,
      user:     creds.user,
      lease_id: creds.leaseId,
    });

    emitRotation(vaultRole, creds);

    if (running) {
      scheduleRenewal(vaultRole, creds.ttl);
    }

    return creds;
  })();

  try {
    return await state.rotationInProgress;
  } finally {
    state.rotationInProgress = null;
  }
}

// ---------------------------------------------------------------------------
// Proactive renewal (per role)
// ---------------------------------------------------------------------------

function scheduleRenewal(vaultRole, ttlSeconds) {
  const state = getRoleState(vaultRole);

  if (state.renewalTimer) {
    clearTimeout(state.renewalTimer);
    state.renewalTimer = null;
  }

  const delayMs = Math.floor(ttlSeconds * RENEWAL_THRESHOLD * 1000);

  log.info("Next renewal scheduled", {
    role:          vaultRole,
    delay_sec:     Math.round(delayMs / 1000),
    threshold_pct: Math.round(RENEWAL_THRESHOLD * 100),
    ttl:           ttlSeconds,
  });

  const timer = setTimeout(() => performRenewal(vaultRole, 0), delayMs);
  if (timer.unref) timer.unref();
  state.renewalTimer = timer;
}

async function performRenewal(vaultRole, retryIndex) {
  const state = getRoleState(vaultRole);

  try {
    log.info("Proactive renewal starting", { role: vaultRole });

    await refreshCredentials(vaultRole, "proactive");

    state.lastRenewalError = null;
    log.info("Proactive renewal complete", { role: vaultRole });
  } catch (err) {
    state.lastRenewalError = err.message;
    log.error("Proactive renewal failed", { role: vaultRole, error: err.message });

    const delay = RETRY_DELAYS[Math.min(retryIndex, RETRY_DELAYS.length - 1)];
    log.warn("Renewal retry scheduled", { role: vaultRole, delay, attempt: retryIndex + 1 });

    const timer = setTimeout(() => performRenewal(vaultRole, retryIndex + 1), delay * 1000);
    if (timer.unref) timer.unref();
    state.renewalTimer = timer;
  }
}

// ---------------------------------------------------------------------------
// Lease management (vault mode)
// ---------------------------------------------------------------------------

async function revokeLease(leaseId) {
  if (!leaseId) return;

  const token = await getVaultToken();

  const res = await fetch(`${VAULT_ADDR}/v1/sys/leases/revoke`, {
    method:  "POST",
    headers: { "Content-Type": "application/json", "X-Vault-Token": token },
    body:    JSON.stringify({ lease_id: leaseId }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Lease revoke failed ${res.status}: ${text}`);
  }

  log.info("Lease revoked", { lease_id: leaseId });
}

async function lookupLease(leaseId) {
  if (!leaseId) return { exists: false, status: "missing", ttl: null };

  const token = await getVaultToken();

  const res = await fetch(`${VAULT_ADDR}/v1/sys/leases/lookup`, {
    method:  "POST",
    headers: { "Content-Type": "application/json", "X-Vault-Token": token },
    body:    JSON.stringify({ lease_id: leaseId }),
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

// ---------------------------------------------------------------------------
// Lease info (per role)
// ---------------------------------------------------------------------------

function vaultGetLeaseInfo(vaultRole) {
  if (vaultRole) return leaseInfoForRole(vaultRole);

  const result = {};
  for (const [role] of roleState) {
    result[role] = leaseInfoForRole(role);
  }
  return result;
}

function leaseInfoForRole(vaultRole) {
  const state = roleState.get(vaultRole);

  if (!state?.credentials) {
    return { status: "no-credentials", vaultRole, leaseId: null, remainingMs: 0, path: null };
  }

  const remainingMs = Math.max(0, state.expiresAt - Date.now());

  return {
    vaultRole,
    leaseId:      state.leaseId,
    user:         state.credentials.user,
    path:         state.credentials.path,
    ttl:          state.credentials.ttl,
    remainingMs,
    remainingSec: Math.round(remainingMs / 1000),
    renewalError: state.lastRenewalError,
    issuedAt:     new Date(state.credentials.issuedAt).toISOString(),
    expiresAt:    new Date(state.expiresAt).toISOString(),
    issuedFor:    state.credentials.issuedFor,
  };
}

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║  UNIFIED EXPORTS                                                         ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

module.exports = {
  MODE,
  resolveVaultRole,
  getKnownRoles,
  onRotation,

  getCredentials: MODE === "vault"
    ? async function getCredentials(userContext) {
        const vaultRole = resolveVaultRole(userContext?.role);
        const state     = getRoleState(vaultRole);
        const now       = Date.now();

        if (state.credentials && state.expiresAt > now + 30_000) {
          return state.credentials;
        }

        return refreshCredentials(vaultRole, "cache-expired", userContext);
      }
    : async function getCredentials() {
        return staticCredentials;
      },

  forceRotation: MODE === "vault"
    ? async function forceRotation(reason, userContext) {
        const vaultRole = resolveVaultRole(userContext?.role);

        log.warn("Forced rotation triggered", { role: vaultRole, reason });

        cachedVaultToken  = null;
        vaultTokenExpires = 0;

        return refreshCredentials(vaultRole, reason, userContext);
      }
    : async function forceRotation(reason) {
        log.info("Force rotation ignored in static mode", { reason });
        return staticCredentials;
      },

  startAutoRenewal: MODE === "vault"
    ? async function startAutoRenewal() {
        running = true;

        const roles   = getKnownRoles();
        const results = new Map();

        for (const vaultRole of roles) {
          try {
            const creds = await refreshCredentials(vaultRole, "initial");
            results.set(vaultRole, creds);
          } catch (err) {
            log.error("Failed to fetch initial credentials", { role: vaultRole, error: err.message });
          }
        }

        log.info("Auto-renewal started", { roles: results.size, of: roles.length });
        return results;
      }
    : async function startAutoRenewal() {
        log.info("Auto-renewal not applicable in static mode");
        return new Map([["static", staticCredentials]]);
      },

  stop: MODE === "vault"
    ? function stop() {
        running = false;

        for (const [, state] of roleState) {
          if (state.renewalTimer) {
            clearTimeout(state.renewalTimer);
            state.renewalTimer = null;
          }
        }

        log.info("Auto-renewal stopped");
      }
    : function stop() {
        log.info("Nothing to stop in static mode");
      },

  getLeaseInfo: MODE === "vault"
    ? vaultGetLeaseInfo
    : function getLeaseInfo() {
        return {
          static: {
            status:       "static",
            vaultRole:    "static",
            leaseId:      null,
            user:         DB_USER,
            ttl:          null,
            remainingMs:  null,
            remainingSec: null,
            issuedAt:     new Date(staticCredentials.issuedAt).toISOString(),
            expiresAt:    null,
            issuedFor:    "system",
            path:         ".env",
          },
        };
      },

  revokeLease: MODE === "vault"
    ? revokeLease
    : async function revokeLease() {},

  lookupLease: MODE === "vault"
    ? lookupLease
    : async function lookupLease() {
        return { exists: false, status: "static", ttl: null };
      },
};
