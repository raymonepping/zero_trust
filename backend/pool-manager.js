"use strict";

const { Pool } = require("pg");
const connector = require("./connector");

// PostgreSQL auth / connection errors that indicate credentials are invalid
const AUTH_ERROR_CODES = new Set(["28P01", "28000", "08006"]);

const POOL_CONFIG = {
  max: 10,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
};

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let activePool = null;
let currentUser = null;
let rotationCount = 0;

let rotationInProgress = null;
let shuttingDown = false;

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
// Pool builder
// ---------------------------------------------------------------------------

function buildPool(credentials) {
  if (VAULT_SOURCED.has(credentials.source)) {
    return new Pool({
      host: credentials.host,
      port: credentials.port,
      database: credentials.database,
      user: credentials.user,
      password: credentials.password,
      ...POOL_CONFIG,
    });
  }

  const connectionString = process.env.DATABASE_URL;

  if (!connectionString) {
    throw new Error("DATABASE_URL not set");
  }

  return new Pool({
    connectionString,
    ...POOL_CONFIG,
  });
}

// ---------------------------------------------------------------------------
// Validate new pool before swap
// ---------------------------------------------------------------------------

async function validatePool(pool) {
  await pool.query("SELECT 1");
}

// ---------------------------------------------------------------------------
// Internal atomic rotation
// ---------------------------------------------------------------------------

async function performRotation(credentials, reason = "unknown") {
  const oldPool = activePool;
  const newPool = buildPool(credentials);

  try {
    await validatePool(newPool);
  } catch (err) {
    await newPool.end().catch(() => {});
    throw new Error(`Pool validation failed: ${err.message}`);
  }

  activePool = newPool;

  if (credentials.previousLeaseId) {
    try {
      await connector.revokeLease(credentials.previousLeaseId);
    } catch (err) {
      console.error(
        "[pool-manager] Old lease revoke failed:",
        err.message
      );
    }
  }
    
  currentUser = credentials.user;
  rotationCount++;

  console.log(
    `[pool-manager] Pool rotated | reason: ${reason} | user: ${credentials.user} | rotation #${rotationCount}`
  );

  if (oldPool && oldPool !== newPool) {
    try {
      await oldPool.end();
    } catch (err) {
      console.error("[pool-manager] Old pool drain failed:", err.message);
    }
  }
}

// ---------------------------------------------------------------------------
// Rotation lock wrapper
// ---------------------------------------------------------------------------

async function rotatePool(credentials, reason = "unknown") {
  if (rotationInProgress) {
    await rotationInProgress;
    return;
  }

  rotationInProgress = performRotation(credentials, reason);

  try {
    await rotationInProgress;
  } finally {
    rotationInProgress = null;
  }
}

// ---------------------------------------------------------------------------
// Proactive rotation callback
// ---------------------------------------------------------------------------

async function handleProactiveRotation(credentials) {
  try {
    await rotatePool(credentials, "proactive");
  } catch (err) {
    console.error("[pool-manager] Proactive rotation failed:", err.message);
  }
}

// ---------------------------------------------------------------------------
// Reactive credential recovery
// ---------------------------------------------------------------------------

let recoveryInProgress = null;

async function recoverFromAuthFailure() {
  if (recoveryInProgress) {
    return recoveryInProgress;
  }

  recoveryInProgress = (async () => {
    let freshCreds;

    if (typeof connector.forceRotation === "function") {
      freshCreds = await connector.forceRotation("auth-error");
    } else {
      freshCreds = await connector.getCredentials();
    }

    await rotatePool(freshCreds, "reactive");
  })();

  try {
    return await recoveryInProgress;
  } finally {
    recoveryInProgress = null;
  }
}

// ---------------------------------------------------------------------------
// Query wrapper
// ---------------------------------------------------------------------------

async function query(sql, params) {
  if (shuttingDown) {
    throw new Error("Server is shutting down");
  }

  if (!activePool) {
    throw new Error("Pool not initialized");
  }

  try {
    return await activePool.query(sql, params);
  } catch (err) {
    if (!AUTH_ERROR_CODES.has(err.code)) {
      throw err;
    }

    console.warn(
      `[pool-manager] Auth error detected (${err.code}), attempting recovery`
    );

    try {
      await recoverFromAuthFailure();
    } catch (rotationErr) {
      console.error(
        "[pool-manager] Reactive rotation failed:",
        rotationErr.message
      );
      throw err;
    }

    return activePool.query(sql, params);
  }
}

// ---------------------------------------------------------------------------
// Initialize
// ---------------------------------------------------------------------------

async function initialize() {
  let credentials;

  if (typeof connector.startAutoRenewal === "function") {
    connector.onRotation(handleProactiveRotation);
    credentials = await connector.startAutoRenewal();

    console.log("[pool-manager] Auto-renewal mode active");
  } else {
    credentials = await connector.getCredentials();

    console.log("[pool-manager] Simple credential mode");
  }

  await rotatePool(credentials, "initial");

  console.log("[pool-manager] Initialized");
}

// ---------------------------------------------------------------------------
// Shutdown
// ---------------------------------------------------------------------------

async function shutdown() {
  shuttingDown = true;

  if (typeof connector.stop === "function") {
    connector.stop();
  }

  if (rotationInProgress) {
    await rotationInProgress.catch(() => {});
  }

  if (activePool) {
    try {
      await activePool.end();
    } catch (err) {
      console.error("[pool-manager] Shutdown drain failed:", err.message);
    }

    activePool = null;
  }

  console.log("[pool-manager] Shutdown complete");
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

function getStatus() {
  const leaseInfo =
    typeof connector.getLeaseInfo === "function"
      ? connector.getLeaseInfo()
      : { status: "not-supported" };

  return {
    currentUser,
    rotationCount,
    rotationActive: !!rotationInProgress,
    shuttingDown,
    pool: activePool
      ? {
          totalCount: activePool.totalCount,
          idleCount: activePool.idleCount,
          waitingCount: activePool.waitingCount,
        }
      : null,
    lease: leaseInfo,
  };
}

module.exports = {
  initialize,
  shutdown,
  query,
  getStatus,
  rotatePool,
};