"use strict";

const express     = require("express");
const morgan      = require("morgan");
const poolManager = require("./pool-manager");
const connector   = require("./connector");
const log         = require("./logger");
const { authenticateOptional } = require("./auth");

const app         = express();
const PORT        = process.env.PORT || 3000;
const OLLAMA_ADDR = process.env.OLLAMA_ADDR || "http://ollama:11434";

app.use(express.json());
app.use(morgan("combined", { stream: log.stream }));

// ---------------------------------------------------------------------------
// Trust level — derived from the active connector's source field
//
// Level 0 (public)                  — static-config, env-file
// Level 1 (internal)                — vault-kv, vault-dynamic
// Level 2 (confidential)            — vault-approle, vault-approle-dynamic
// Level 3 (restricted — full trust) — vault-jwt-dynamic
//
// This is orthogonal to user role scoping:
//   - Trust level controls which data CLASSIFICATIONS are queryable (SQL WHERE)
//   - User role controls which Vault DB ROLE (and SQL GRANTs) the credential carries
//   - Both layers enforce independently (defense in depth)
// ---------------------------------------------------------------------------

const TRUST_LEVELS = {
  "static-config":         0,
  "env-file":              0,
  "vault-kv":              1,
  "vault-dynamic":         1,
  "vault-approle":         2,
  "vault-approle-dynamic": 2,
  "vault-jwt-dynamic":     3,
};

const CLASSIFICATIONS = ["public", "internal", "confidential", "restricted"];

const RENEWAL_THRESHOLD = 0.75;

// ---------------------------------------------------------------------------
// Backward-compatibility helpers — tolerate old connectors that lack
// MODE, resolveVaultRole, getKnownRoles, and lookupLease
// ---------------------------------------------------------------------------

const connectorMode        = connector.MODE || "legacy";
const connectorResolveRole = typeof connector.resolveVaultRole === "function"
  ? (role) => connector.resolveVaultRole(role)
  : () => "app-role";
const connectorKnownRoles  = typeof connector.getKnownRoles === "function"
  ? () => connector.getKnownRoles()
  : () => ["app-role"];
const connectorLookupLease = typeof connector.lookupLease === "function"
  ? (id) => connector.lookupLease(id)
  : async () => ({ exists: null, status: "not-supported", ttl: null });
const connectorGetLeaseInfo = typeof connector.getLeaseInfo === "function"
  ? () => connector.getLeaseInfo()
  : () => null;

function getAllowedClassifications(source) {
  const level = TRUST_LEVELS[source] ?? 0;
  return CLASSIFICATIONS.slice(0, level + 1);
}

async function getActiveSource(userContext) {
  try {
    const creds = await connector.getCredentials(userContext);
    return creds.source || "static-config";
  } catch {
    return "static-config";
  }
}

function sqlInList(values) {
  return values.map((v) => `'${v}'`).join(", ");
}

// ---------------------------------------------------------------------------
// Vault health probe — hits /v1/sys/health (no token required)
// Returns { ok, status, sealed, version } — never throws
// ---------------------------------------------------------------------------
const VAULT_ADDR = process.env.VAULT_ADDR || "http://vault:8200";

async function probeVault() {
  try {
    const res = await fetch(
      `${VAULT_ADDR}/v1/sys/health?standbyok=true&perfstandbyok=true`,
      { signal: AbortSignal.timeout(3000) }
    );
    const json      = await res.json().catch(() => ({}));
    const reachable = res.status !== 503 && res.status !== 501;
    if (!reachable) {
      const msg = json.errors?.[0] || (res.status === 503 ? "sealed" : "not initialised");
      log.warn("Vault health degraded", { status: res.status, msg });
      return { ok: false, status: msg, sealed: res.status === 503, version: json.version || null };
    }
    return { ok: true, status: "active", sealed: false, version: json.version || null };
  } catch (err) {
    log.error("Vault health error", { error: err.message });
    return { ok: false, status: err.message, sealed: null, version: null };
  }
}

// ---------------------------------------------------------------------------
// Health — no auth required
// ---------------------------------------------------------------------------
app.get("/", async (_req, res) => {
  try {
    await poolManager.query("SELECT 1");
    res.json({ status: "ok", message: "database is connected" });
  } catch (err) {
    res.status(500).json({ status: "error", message: err.message });
  }
});

app.get("/health", async (_req, res) => {
  const [dbResult, vaultResult] = await Promise.allSettled([
    poolManager.query("SELECT 1"),
    probeVault(),
  ]);

  const dbOk    = dbResult.status === "fulfilled";
  const vaultOk = vaultResult.status === "fulfilled" && vaultResult.value.ok;
  const vault   = vaultResult.status === "fulfilled" ? vaultResult.value : { ok: false, status: "probe failed" };

  const overall    = dbOk && vaultOk ? "ok" : "degraded";
  const httpStatus = dbOk ? 200 : 503;

  if (!vaultOk) {
    log.warn("Health check: Vault degraded", { vault: vault.status });
  }

  res.status(httpStatus).json({
    status: overall,
    mode:   connectorMode,
    db:     dbOk ? "connected" : dbResult.reason?.message || "error",
    vault: {
      status:  vault.status,
      ok:      vault.ok,
      sealed:  vault.sealed ?? null,
      version: vault.version || null,
    },
  });
});

// ---------------------------------------------------------------------------
// Data APIs — authenticateOptional keeps the frontend working without a
// Bearer token while enabling role-scoped credentials when one is present
// ---------------------------------------------------------------------------
app.get("/users", authenticateOptional, async (req, res) => {
  try {
    const { rows } = await poolManager.query(
      "SELECT id, first_name, last_name, email, city, country, joined FROM users ORDER BY id",
      [],
      req.userContext,
    );
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get("/orders", authenticateOptional, async (req, res) => {
  try {
    const source  = await getActiveSource(req.userContext);
    const allowed = getAllowedClassifications(source);
    const { rows } = await poolManager.query(
      `SELECT o.id, u.first_name, u.last_name, o.item, o.category,
              o.quantity, o.price, o.ordered_at, o.classification
       FROM orders o
       JOIN users u ON u.id = o.user_id
       WHERE o.classification IN (${sqlInList(allowed)})
       ORDER BY o.ordered_at DESC`,
      [],
      req.userContext,
    );
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get("/preferences", authenticateOptional, async (req, res) => {
  try {
    const source  = await getActiveSource(req.userContext);
    const allowed = getAllowedClassifications(source);
    const { rows } = await poolManager.query(
      `SELECT p.id, u.first_name, u.last_name, p.category, p.value, p.classification
       FROM preferences p
       JOIN users u ON u.id = p.user_id
       WHERE p.classification IN (${sqlInList(allowed)})
       ORDER BY u.id, p.category`,
      [],
      req.userContext,
    );
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Credentials — includes trust level, role scoping, and pool status
// ---------------------------------------------------------------------------
app.get("/credentials", authenticateOptional, async (req, res) => {
  try {
    const creds   = await connector.getCredentials(req.userContext);
    const status  = poolManager.getStatus();
    const allowed = getAllowedClassifications(creds.source);
    const level   = TRUST_LEVELS[creds.source] ?? 0;

    res.json({
      source:                  creds.source,
      path:                    creds.path      || null,
      host:                    creds.host,
      port:                    creds.port,
      database:                creds.database,
      username:                creds.user,
      password:                "***",
      ttl:                     creds.ttl       || null,
      leaseId:                 creds.leaseId   || null,
      vaultRole:               creds.vaultRole || null,
      issuedFor:               creds.issuedFor || null,
      trust_level:             level,
      allowed_classifications: allowed,
      requestedBy:             req.userContext || null,
      pools:                   status.pools,
      leases:                  status.leases,
      rotations:               status.rotationCount,
    });
  } catch (err) {
    res.status(502).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Lease health — per-role lease status with live Vault truth
// ---------------------------------------------------------------------------
app.get("/health/lease", async (_req, res) => {
  try {
    const poolStatus = poolManager.getStatus();
    const leases     = connectorGetLeaseInfo();

    if (!leases || Object.keys(leases).length === 0) {
      return res.json({ status: "no-credentials", roles: {}, rotation_active: false });
    }

    const roles = {};

    for (const [vaultRole, lease] of Object.entries(leases)) {
      const renewalWindowSec = (lease.ttl || 0) * (1 - RENEWAL_THRESHOLD);
      const poolState        = poolStatus.pools?.[vaultRole];
      const rotating         = poolState?.rotationCount !== undefined && poolStatus.rotationActive;

      let localStatus;
      if (rotating) {
        localStatus = "rotating";
      } else if (lease.remainingSec !== null && lease.remainingSec <= 0) {
        localStatus = "expired";
      } else if (lease.renewalError) {
        localStatus = "degraded";
      } else if (lease.remainingSec !== null && lease.remainingSec < renewalWindowSec) {
        localStatus = "renewing";
      } else {
        localStatus = lease.status || "active";
      }

      // Live Vault truth — only when vault mode and lease exists
      let vaultStatus = "unknown";
      if (lease.leaseId && connectorMode === "vault") {
        try {
          const lookup = await connectorLookupLease(lease.leaseId);
          vaultStatus  = lookup.status;

          if (lookup.status === "revoked" && !poolStatus.rotationActive) {
            log.warn("Vault reports lease revoked — triggering recovery", { role: vaultRole });
            connector.forceRotation("vault-revoked", { role: vaultRole }).catch((err) =>
              log.error("Auto-recovery failed", { role: vaultRole, error: err.message })
            );
          }
        } catch (lookupErr) {
          vaultStatus = "lookup-failed";
          log.error("Lease lookup error", { role: vaultRole, error: lookupErr.message });
        }
      }

      roles[vaultRole] = {
        lease_id:      lease.leaseId      || null,
        user:          lease.user         || null,
        ttl:           lease.ttl          || null,
        remaining_sec: lease.remainingSec ?? null,
        issued_at:     lease.issuedAt     || null,
        expires_at:    lease.expiresAt    || null,
        issued_for:    lease.issuedFor    || null,
        local_status:  localStatus,
        vault_status:  vaultStatus,
        ...(lease.renewalError && { renewal_error: lease.renewalError }),
      };
    }

    res.json({
      mode:            connectorMode,
      roles,
      rotation_active: poolStatus.rotationActive,
      rotation_count:  poolStatus.rotationCount,
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post("/health/lease/rotate", async (req, res) => {
  try {
    // Optional: body.role targets a specific JWT role — defaults to all known roles
    const targetRole    = req.body?.role;
    const rolesToRotate = targetRole
      ? [connectorResolveRole(targetRole)]
      : connectorKnownRoles();

    const results = {};

    for (const vaultRole of rolesToRotate) {
      try {
        const creds = await connector.forceRotation("api-request", { role: vaultRole });
        await poolManager.rotatePool(creds, "api-request");
        results[vaultRole] = { rotated: true, user: creds.user };
      } catch (err) {
        results[vaultRole] = { rotated: false, error: err.message };
      }
    }

    const poolStatus = poolManager.getStatus();

    log.info("Forced rotation via API", { roles: Object.keys(results) });

    res.json({
      mode:           connectorMode,
      results,
      rotation_count: poolStatus.rotationCount,
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Ask — context filtered by trust level, queries scoped by user role
// ---------------------------------------------------------------------------
app.post("/ask", authenticateOptional, async (req, res) => {
  const { question } = req.body;
  if (!question) return res.status(400).json({ error: "question is required" });

  const uc = req.userContext;

  try {
    const source  = await getActiveSource(uc);
    const allowed = getAllowedClassifications(source);
    const inList  = sqlInList(allowed);

    const [users, orders, prefs] = await Promise.all([
      poolManager.query(
        "SELECT first_name, last_name, email, city, country, joined FROM users ORDER BY id",
        [], uc,
      ),
      poolManager.query(
        `SELECT u.first_name, o.item, o.category, o.quantity, o.price, o.ordered_at, o.classification
         FROM orders o JOIN users u ON u.id = o.user_id
         WHERE o.classification IN (${inList})
         ORDER BY u.id, o.ordered_at`,
        [], uc,
      ),
      poolManager.query(
        `SELECT u.first_name, p.category, p.value, p.classification
         FROM preferences p JOIN users u ON u.id = p.user_id
         WHERE p.classification IN (${inList})
         ORDER BY u.id, p.category`,
        [], uc,
      ),
    ]);

    const fmt = (rows) => rows.map((r) => JSON.stringify(r)).join("\n");

    const context = `
USERS:
${fmt(users.rows)}

ORDERS (visible at trust level — classifications: ${allowed.join(", ")}):
${fmt(orders.rows)}

PREFERENCES (visible at trust level — classifications: ${allowed.join(", ")}):
${fmt(prefs.rows)}
`.trim();

    const prompt = `You are a helpful assistant with access to a user database.
Use only the data provided below to answer the question. Be concise and friendly.
Note: some data may be hidden based on the current security level (${source}).

--- DATA ---
${context}
--- END DATA ---

Question: ${question}
Answer:`;

    log.info("/ask", {
      user:     uc?.sub   || "anonymous",
      role:     uc?.role  || "none",
      source,
      question: question.substring(0, 80),
    });

    res.setHeader("Content-Type", "text/plain; charset=utf-8");
    res.setHeader("Transfer-Encoding", "chunked");
    res.setHeader("X-Accel-Buffering", "no");

    const ollamaRes = await fetch(`${OLLAMA_ADDR}/api/generate`, {
      method:  "POST",
      headers: { "Content-Type": "application/json" },
      body:    JSON.stringify({ model: "llama3.2", prompt, stream: true }),
    });

    if (!ollamaRes.ok) {
      const err = await ollamaRes.text();
      return res.status(502).end(`Ollama error: ${err}`);
    }

    const reader  = ollamaRes.body.getReader();
    const decoder = new TextDecoder();

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const lines = decoder.decode(value, { stream: true }).split("\n").filter(Boolean);
      for (const line of lines) {
        try {
          const json = JSON.parse(line);
          if (json.response) res.write(json.response);
          if (json.done) { res.end(); return; }
        } catch { /* partial chunk, skip */ }
      }
    }

    res.end();
  } catch (err) {
    if (!res.headersSent) res.status(500).json({ error: err.message });
    else res.end();
  }
});

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

async function gracefulShutdown(signal) {
  log.info(`${signal} received — shutting down`);
  await poolManager.shutdown();
  process.exit(0);
}

process.on("SIGTERM", () => gracefulShutdown("SIGTERM"));
process.on("SIGINT",  () => gracefulShutdown("SIGINT"));

async function start() {
  await poolManager.initialize();
  app.listen(PORT, () => {
    log.info("Backend listening", { port: PORT, mode: connectorMode });
    log.info("Ollama configured", { endpoint: OLLAMA_ADDR });
  });
}

start().catch((err) => {
  log.error("Failed to start", { error: err.message });
  process.exit(1);
});
