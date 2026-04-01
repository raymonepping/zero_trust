/**
 * pool-manager.js — pg.Pool lifecycle manager with credential rotation support
 *
 * Wraps connector.js to:
 *   1. Create and hold a live pg.Pool
 *   2. Atomically swap the pool when credentials rotate (proactive)
 *   3. Detect auth errors mid-query and trigger reactive rotation + retry
 *   4. Drain the old pool gracefully in the background after swap
 *
 * Compatibility: works with both rotation-aware connectors (startAutoRenewal,
 * onRotation, getLeaseInfo) and simple connectors that only export getCredentials.
 */

"use strict";

const { Pool } = require("pg");
const connector = require("./connector");

// Auth error codes that indicate credentials were revoked
const AUTH_ERROR_CODES = new Set(["28P01", "28000", "08006"]);

const POOL_CONFIG = {
  max:             10,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
};

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let activePool    = null;
let currentUser   = null;
let rotationCount = 0;

// ---------------------------------------------------------------------------
// Pool creation
// ---------------------------------------------------------------------------

function buildPool(credentials) {
  return new Pool({
    host:     credentials.host,
    port:     credentials.port,
    database: credentials.database,
    user:     credentials.user,
    password: credentials.password,
    ...POOL_CONFIG,
  });
}

// ---------------------------------------------------------------------------
// Atomic pool swap — drain old pool in background
// ---------------------------------------------------------------------------

async function rotatePool(credentials) {
  const oldPool = activePool;
  const newPool = buildPool(credentials);

  // Validate new pool before committing the swap
  try {
    await newPool.query("SELECT 1");
  } catch (err) {
    await newPool.end().catch(() => {});
    throw new Error(`New pool validation failed after rotation: ${err.message}`);
  }

  activePool  = newPool;
  currentUser = credentials.user;
  rotationCount++;

  console.log(
    `[pool-manager] Pool rotated | user: ${credentials.user} | rotation #${rotationCount}`
  );

  // Drain old pool in background
  if (oldPool) {
    setImmediate(() => {
      oldPool.end().catch((err) =>
        console.error("[pool-manager] Error draining old pool:", err.message)
      );
    });
  }
}

// ---------------------------------------------------------------------------
// Rotation handler (called by connector's onRotation callback)
// ---------------------------------------------------------------------------

async function handleProactiveRotation(credentials) {
  try {
    await rotatePool(credentials);
  } catch (err) {
    console.error("[pool-manager] Proactive rotation failed:", err.message);
  }
}

// ---------------------------------------------------------------------------
// Public: query — with reactive rotation on auth failure
// ---------------------------------------------------------------------------

async function query(sql, params) {
  if (!activePool) throw new Error("Pool not initialized — call initialize() first");

  try {
    return await activePool.query(sql, params);
  } catch (err) {
    if (!AUTH_ERROR_CODES.has(err.code)) throw err;

    console.warn(
      `[pool-manager] Auth error detected (${err.code}), triggering reactive rotation...`
    );

    try {
      let freshCreds;
      if (typeof connector.forceRotation === "function") {
        freshCreds = await connector.forceRotation("auth-error");
      } else {
        freshCreds = await connector.getCredentials();
      }
      await rotatePool(freshCreds);
    } catch (rotErr) {
      console.error("[pool-manager] Reactive rotation failed:", rotErr.message);
      throw err; // throw original auth error
    }

    // Retry once with fresh credentials
    return activePool.query(sql, params);
  }
}

// ---------------------------------------------------------------------------
// Public: initialize
// ---------------------------------------------------------------------------

async function initialize() {
  let credentials;

  if (typeof connector.startAutoRenewal === "function") {
    // Rotation-aware connector: startAutoRenewal fetches initial creds and
    // kicks off the proactive renewal timer
    connector.onRotation(handleProactiveRotation);
    credentials = await connector.startAutoRenewal();
    console.log("[pool-manager] Auto-renewal mode active");
  } else {
    // Simple connector (wired, env, vault-kv, etc.): fetch once, no rotation
    credentials = await connector.getCredentials();
    console.log("[pool-manager] Simple connector mode (no auto-renewal)");
  }

  await rotatePool(credentials);
  console.log("[pool-manager] Initialized");
}

// ---------------------------------------------------------------------------
// Public: shutdown
// ---------------------------------------------------------------------------

async function shutdown() {
  if (typeof connector.stop === "function") {
    connector.stop();
  }

  if (activePool) {
    await activePool.end().catch((err) =>
      console.error("[pool-manager] Error during shutdown:", err.message)
    );
    activePool = null;
  }

  console.log("[pool-manager] Shutdown complete");
}

// ---------------------------------------------------------------------------
// Public: getStatus
// ---------------------------------------------------------------------------

function getStatus() {
  const leaseInfo =
    typeof connector.getLeaseInfo === "function"
      ? connector.getLeaseInfo()
      : { status: "not-supported" };

  return {
    currentUser,
    rotationCount,
    pool: activePool
      ? {
          totalCount:   activePool.totalCount,
          idleCount:    activePool.idleCount,
          waitingCount: activePool.waitingCount,
        }
      : null,
    lease: leaseInfo,
  };
}

module.exports = { initialize, shutdown, query, getStatus };
