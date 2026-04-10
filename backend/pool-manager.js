"use strict";

const { Pool } = require("pg");
const connector = require("./connector");
const log       = require("./logger");

const AUTH_ERROR_CODES = new Set(["28P01", "28000", "08006"]);

const POOL_CONFIG = {
  max:                    10,
  idleTimeoutMillis:      30_000,
  connectionTimeoutMillis: 5_000,
};

// ---------------------------------------------------------------------------
// State: per-role pools
// Map<vaultRole, { pool, user, rotationCount, rotationInProgress, recoveryInProgress }>
// ---------------------------------------------------------------------------

const pools       = new Map();
let shuttingDown  = false;
let initialized   = false;

function getPoolState(vaultRole) {
  if (!pools.has(vaultRole)) {
    pools.set(vaultRole, {
      pool:               null,
      user:               null,
      rotationCount:      0,
      rotationInProgress: null,
      recoveryInProgress: null,
    });
  }
  return pools.get(vaultRole);
}

// ---------------------------------------------------------------------------
// Credential source classification
// ---------------------------------------------------------------------------

const VAULT_SOURCED = new Set([
  "vault-kv",
  "vault-dynamic",
  "vault-approle",
  "vault-approle-dynamic",
  "vault-jwt-dynamic",
]);

// ---------------------------------------------------------------------------
// Backward-compatibility shims for older connectors (phases 0-4)
// that predate the role-scoped interface.
//
// Old connectors lack: MODE, resolveVaultRole, getKnownRoles, lookupLease
// Old startAutoRenewal() returns a single credentials object (not a Map)
// Old emitRotation fires listeners with (credentials) — one argument
// ---------------------------------------------------------------------------

const DEFAULT_ROLE = "viewer-read";

// Resolve which pool to use for a given userContext.
// Falls back to DEFAULT_ROLE for old connectors without resolveVaultRole.
function resolveRole(userContext) {
  if (userContext?.role) {
    return userContext.role;
  }

  // Legacy connector fallback only
  return pools.size > 0 ? [...pools.keys()][0] : "viewer-read";
}

// Normalise startAutoRenewal() return value to Map<vaultRole, credentials>
function normalizeCredsMap(result) {
  if (result instanceof Map) return result;
  // Old connector returns a single credentials object
  const role = result?.vaultRole || DEFAULT_ROLE;
  return new Map([[role, result]]);
}

// Normalise getLeaseInfo() to { [vaultRole]: leaseInfo } for old connectors
// that return a flat single-lease object { leaseId, user, ttl, ... }
function normalizeLeaseInfo(result) {
  if (!result) return {};
  // New format: keys are vault roles, values are lease objects with vaultRole field
  const firstVal = Object.values(result)[0];
  if (firstVal && typeof firstVal === "object" && "vaultRole" in firstVal) {
    return result; // already per-role format
  }
  // Old flat format: wrap in a role-keyed object
  const role = result.vaultRole || DEFAULT_ROLE;
  return { [role]: { ...result, vaultRole: role } };
}

// Shims for lifecycle functions absent from early-stage workshop connectors
const connectorStartAutoRenewal = typeof connector.startAutoRenewal === "function"
  ? () => connector.startAutoRenewal()
  : typeof connector.start === "function"
    ? () => connector.start()
    : async () => connector.getCredentials();

const connectorOnRotation = typeof connector.onRotation === "function"
  ? (cb) => connector.onRotation(cb)
  : () => {};

const connectorStop = typeof connector.stop === "function"
  ? () => connector.stop()
  : () => {};

const connectorRevokeLease = typeof connector.revokeLease === "function"
  ? (id) => connector.revokeLease(id)
  : async () => {};

const connectorForceRotation = typeof connector.forceRotation === "function"
  ? (reason, ctx) => connector.forceRotation(reason, ctx)
  : (_reason, ctx) => connector.getCredentials(ctx);

// ---------------------------------------------------------------------------
// Pool builder
// ---------------------------------------------------------------------------

function buildPool(credentials) {
  if (VAULT_SOURCED.has(credentials.source)) {
    return new Pool({
      host:     credentials.host,
      port:     credentials.port,
      database: credentials.database,
      user:     credentials.user,
      password: credentials.password,
      ...POOL_CONFIG,
    });
  }

  // Static mode: use individual fields (DB_USER/DB_PASSWORD from connector)
  // Fall through to DATABASE_URL only if individual fields are absent
  if (credentials.host && credentials.user && credentials.password) {
    return new Pool({
      host:     credentials.host,
      port:     credentials.port,
      database: credentials.database,
      user:     credentials.user,
      password: credentials.password,
      ...POOL_CONFIG,
    });
  }

  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) throw new Error("DATABASE_URL not set");
  return new Pool({ connectionString, ...POOL_CONFIG });
}

async function validatePool(pool) {
  await pool.query("SELECT 1");
}

// ---------------------------------------------------------------------------
// Internal atomic rotation (per role)
// ---------------------------------------------------------------------------

async function performRotation(vaultRole, credentials, reason) {
  const state   = getPoolState(vaultRole);
  const oldPool = state.pool;
  const newPool = buildPool(credentials);

  try {
    await validatePool(newPool);
  } catch (err) {
    await newPool.end().catch(() => {});
    throw new Error(`Pool validation failed for "${vaultRole}": ${err.message}`);
  }

  state.pool = newPool;
  state.user = credentials.user;
  state.rotationCount++;

  log.info("Pool rotated", {
    role:           vaultRole,
    reason,
    user:           credentials.user,
    rotation_count: state.rotationCount,
    source:         credentials.source,
  });

  // Revoke previous lease after swap
  if (credentials.previousLeaseId) {
    try {
      await connectorRevokeLease(credentials.previousLeaseId);
    } catch (err) {
      log.error("Old lease revoke failed", {
        role:     vaultRole,
        lease_id: credentials.previousLeaseId,
        error:    err.message,
      });
    }
  }

  // Drain old pool
  if (oldPool && oldPool !== newPool) {
    try {
      await oldPool.end();
    } catch (err) {
      log.warn("Old pool drain failed", { role: vaultRole, error: err.message });
    }
  }
}

// ---------------------------------------------------------------------------
// Rotation lock wrapper (per role)
// ---------------------------------------------------------------------------

async function rotatePool(vaultRole, credentials, reason) {
  const state = getPoolState(vaultRole);

  if (state.rotationInProgress) {
    await state.rotationInProgress;
    return;
  }

  state.rotationInProgress = performRotation(vaultRole, credentials, reason);

  try {
    await state.rotationInProgress;
  } finally {
    state.rotationInProgress = null;
  }
}

// ---------------------------------------------------------------------------
// Proactive rotation callback (registered with connector.onRotation)
// ---------------------------------------------------------------------------

async function handleProactiveRotation(vaultRole, credentials) {
  // Old connectors call emitRotation(credentials) with one arg — normalise
  if (credentials === undefined && vaultRole && typeof vaultRole === "object") {
    credentials = vaultRole;
    vaultRole   = credentials.vaultRole || resolveRole(null);
  }
  try {
    await rotatePool(vaultRole, credentials, "proactive");
  } catch (err) {
    log.error("Proactive rotation failed", { role: vaultRole, error: err.message });
  }
}

// ---------------------------------------------------------------------------
// Reactive credential recovery (per role)
// ---------------------------------------------------------------------------

async function recoverFromAuthFailure(vaultRole, userContext) {
  const state = getPoolState(vaultRole);

  if (state.recoveryInProgress) {
    return state.recoveryInProgress;
  }

  state.recoveryInProgress = (async () => {
    const freshCreds = await connectorForceRotation("auth-error", userContext);
    await rotatePool(vaultRole, freshCreds, "reactive");
  })();

  try {
    return await state.recoveryInProgress;
  } finally {
    state.recoveryInProgress = null;
  }
}

// ---------------------------------------------------------------------------
// Query wrapper (role-aware)
// ---------------------------------------------------------------------------

async function query(sql, params, userContext) {
  if (shuttingDown) throw new Error("Server is shutting down");
  if (!initialized) throw new Error("Pool not initialized");

  const vaultRole = resolveRole(userContext);
  const allowedRoles = new Set(["viewer-read", "support-read", "admin-read"]);

  if (!allowedRoles.has(vaultRole)) {
    throw new Error(`Invalid vault role: ${vaultRole}`);
  }
  
  let state       = getPoolState(vaultRole);

  // Lazy pool creation for roles not pre-warmed at startup
  if (!state.pool) {
    log.info("Lazy pool init", { role: vaultRole });
    const creds = await connector.getCredentials(userContext);
    await rotatePool(vaultRole, creds, "lazy-init");
    state = getPoolState(vaultRole);
  }

  try {
    return await state.pool.query(sql, params);
  } catch (err) {
    if (!AUTH_ERROR_CODES.has(err.code)) throw err;

    log.warn("Auth error detected, attempting recovery", { role: vaultRole, code: err.code });

    try {
      await recoverFromAuthFailure(vaultRole, userContext);
    } catch (rotationErr) {
      log.error("Reactive rotation failed", { role: vaultRole, error: rotationErr.message });
      throw err;
    }

    return getPoolState(vaultRole).pool.query(sql, params);
  }
}

// ---------------------------------------------------------------------------
// Initialize
// ---------------------------------------------------------------------------

async function initialize() {
  if (initialized) return;

  // startAutoRenewal() fetches credentials and calls emitRotation() internally.
  // Register the proactive rotation listener AFTER it returns so the initial
  // credential fetch does not trigger a pool rotation before we build the pool.
  const credsMap = normalizeCredsMap(await connectorStartAutoRenewal());

  for (const [vaultRole, creds] of credsMap) {
    try {
      await rotatePool(vaultRole, creds, "initial");
    } catch (err) {
      log.error("Failed to create pool", { role: vaultRole, error: err.message });
    }
  }

  // Now safe to register — all future proactive renewals will rotate the pool.
  connectorOnRotation(handleProactiveRotation);

  initialized = true;
  log.info("Pool manager initialized", { pools: pools.size });
}

// ---------------------------------------------------------------------------
// Shutdown
// ---------------------------------------------------------------------------

async function shutdown() {
  shuttingDown = true;
  connectorStop();

  // Wait for in-progress rotations
  for (const [, state] of pools) {
    if (state.rotationInProgress) {
      await state.rotationInProgress.catch(() => {});
    }
  }

  // Drain all pools in parallel
  await Promise.all(
    [...pools.entries()].map(([vaultRole, state]) =>
      state.pool
        ? state.pool.end().catch((err) =>
            log.warn("Shutdown drain failed", { role: vaultRole, error: err.message })
          )
        : Promise.resolve()
    )
  );

  pools.clear();
  initialized = false;
  log.info("Pool manager shutdown complete");
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

function getStatus() {
  const leases = normalizeLeaseInfo(
    typeof connector.getLeaseInfo === "function" ? connector.getLeaseInfo() : null
  );
  const poolStatus      = {};
  let totalRotations    = 0;
  let anyRotationActive = false;

  for (const [vaultRole, state] of pools) {
    totalRotations += state.rotationCount;
    if (state.rotationInProgress) anyRotationActive = true;

    poolStatus[vaultRole] = {
      user:          state.user,
      rotationCount: state.rotationCount,
      ...(state.pool ? {
        totalCount:   state.pool.totalCount,
        idleCount:    state.pool.idleCount,
        waitingCount: state.pool.waitingCount,
      } : { totalCount: 0, idleCount: 0, waitingCount: 0 }),
    };
  }

  return {
    mode:           connector.MODE,
    initialized,
    shuttingDown,
    rotationCount:  totalRotations,
    rotationActive: anyRotationActive,
    pools:          poolStatus,
    leases,
  };
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

module.exports = {
  initialize,
  shutdown,
  query,
  getStatus,

  // Exposed for manual rotation endpoint
  rotatePool: async function (credentials, reason) {
    const vaultRole = credentials.vaultRole || resolveRole(null);
    await rotatePool(vaultRole, credentials, reason);
  },
};
