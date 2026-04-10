"use strict";

const express     = require("express");
const morgan      = require("morgan");

const poolManager = require("./pool-manager");
const connector   = require("./connector");
const log         = require("./logger");

const { authenticateOptional } = require("./auth");
const { resolveVaultRole } = require("./roleResolver");
const cibaRoutes = require("./ciba-routes");
const openapiRoutes = require("./openapi-routes");

const app         = express();
const PORT        = process.env.PORT || 3000;
const OLLAMA_ADDR = process.env.OLLAMA_ADDR || "http://ollama:11434";
const EXPOSE_ROUTES = process.env.EXPOSE_ROUTES === "true";

app.use(express.json());
app.use(morgan("combined", { stream: log.stream }));

if (EXPOSE_ROUTES) {
  app.use(openapiRoutes);
}

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
const connectorPhase       = connector.CONNECTOR_PHASE || null;
const connectorCapabilities = connector.CAPABILITIES || {};
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

function selectAskDatasets(question) {
  const q = question.toLowerCase();
  const selected = new Set(["users"]);

  if (/(order|orders|spent|spend|purchase|purchases|bought|buy)/.test(q)) {
    selected.add("orders");
  }
  if (/(preference|preferences|interest|interests|music|sports|cuisine|travel|clearance|salary)/.test(q)) {
    selected.add("preferences");
  }
  if (/(training|course|courses|certified|certification|score|completed)/.test(q)) {
    selected.add("training");
  }
  if (/(ticket|tickets|priority|status|open ticket|support load|issue|issues|incident)/.test(q)) {
    selected.add("tickets");
  }
  if (/(project|projects|budget|budgets|highest-budget|highest budget)/.test(q)) {
    selected.add("projects");
  }

  // If nothing beyond users matched, fall back to all datasets for broad questions.
  if (selected.size === 1) {
    return new Set(["users", "orders", "preferences", "training", "tickets", "projects"]);
  }

  return selected;
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
  const needsVault = connectorMode === "vault";

  const [dbResult, vaultResult] = await Promise.allSettled([
    poolManager.query("SELECT 1"),
    needsVault ? probeVault() : Promise.resolve({ ok: true, status: "not-used", sealed: false, version: null }),
  ]);

  const dbOk    = dbResult.status === "fulfilled";
  const vaultOk = !needsVault || (vaultResult.status === "fulfilled" && vaultResult.value.ok);
  const vault   = vaultResult.status === "fulfilled" ? vaultResult.value : { ok: false, status: "probe failed" };

  const overall    = dbOk && vaultOk ? "ok" : "degraded";
  const httpStatus = dbOk ? 200 : 503;

  if (needsVault && !vaultOk) {
    log.warn("Health check: Vault degraded", { vault: vault.status });
  }

  res.status(httpStatus).json({
    status: overall,
    mode:   connectorMode,
    db:     dbOk ? "connected" : dbResult.reason?.message || "error",
    vault:  needsVault
      ? { status: vault.status, ok: vault.ok, sealed: vault.sealed ?? null, version: vault.version || null }
      : { status: "not-used", ok: null, sealed: null, version: null },
  });
});

// ---------------------------------------------------------------------------
// Data APIs — authenticateOptional keeps the frontend working without a
// Bearer token while enabling role-scoped credentials when one is present
// ---------------------------------------------------------------------------
app.get("/users", authenticateOptional, async (req, res) => {
  try {
    const uc = req.userContext
      ? { ...req.userContext, role: resolveVaultRole(req.user) }
      : { role: "viewer-read" };
    const { rows } = await poolManager.query(
      "SELECT id, first_name, last_name, email, city, country, joined FROM users ORDER BY id",
      [],
      uc,
    );
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get("/orders", authenticateOptional, async (req, res) => {
  try {
    const uc = req.userContext
      ? { ...req.userContext, role: resolveVaultRole(req.user) }
      : { role: "viewer-read" };

    const { rows } = await poolManager.query(
      `SELECT o.id, u.first_name, u.last_name, o.item, o.category,
              o.quantity, o.price, o.ordered_at, o.status, o.classification
       FROM orders o
       JOIN users u ON u.id = o.user_id
       ORDER BY o.ordered_at DESC`,
      [],
      uc,
    );

    res.json(rows);
  } catch (err) {
    if (err.code === "42501") return res.json([]);
    res.status(500).json({ error: err.message });
  }
});

app.get("/preferences", authenticateOptional, async (req, res) => {
  try {
    const uc = req.userContext
      ? { ...req.userContext, role: resolveVaultRole(req.user) }
      : { role: "viewer-read" };
    const source  = await getActiveSource(uc);
    const allowed = getAllowedClassifications(source);
    const { rows } = await poolManager.query(
      `SELECT p.id, u.first_name, u.last_name, p.category, p.value, p.classification
       FROM preferences p
       JOIN users u ON u.id = p.user_id
       WHERE p.classification IN (${sqlInList(allowed)})
       ORDER BY u.id, p.category`,
      [],
      uc,
    );
    res.json(rows);
  } catch (err) {
    if (err.code === "42501") return res.json([]);
    res.status(500).json({ error: err.message });
  }
});

app.get("/training", authenticateOptional, async (req, res) => {
  try {
    const uc = req.userContext
      ? { ...req.userContext, role: resolveVaultRole(req.user) }
      : { role: "viewer-read" };
    const source  = await getActiveSource(uc);
    const allowed = getAllowedClassifications(source);
    const { rows } = await poolManager.query(
      `SELECT t.id, u.first_name, u.last_name, t.course, t.provider,
              t.completed_at, t.score, t.certified, t.classification
       FROM training t
       JOIN users u ON u.id = t.user_id
       WHERE t.classification IN (${sqlInList(allowed)})
       ORDER BY t.completed_at DESC, u.id`,
      [],
      uc,
    );
    res.json(rows);
  } catch (err) {
    if (err.code === "42501") return res.json([]);
    log.error("GET /training failed", { error: err.message });
    res.status(500).json({ error: err.message });
  }
});

app.get("/tickets", authenticateOptional, async (req, res) => {
  try {
    const uc = req.userContext
      ? { ...req.userContext, role: resolveVaultRole(req.user) }
      : { role: "viewer-read" };
    const source  = await getActiveSource(uc);
    const allowed = getAllowedClassifications(source);
    const { rows } = await poolManager.query(
      `SELECT t.id, u.first_name, u.last_name, t.title, t.system,
              t.priority, t.status, t.opened_at, t.classification
       FROM tickets t
       JOIN users u ON u.id = t.user_id
       WHERE t.classification IN (${sqlInList(allowed)})
       ORDER BY t.opened_at DESC, u.id`,
      [],
      uc,
    );
    res.json(rows);
  } catch (err) {
    if (err.code === "42501") return res.json([]);
    log.error("GET /tickets failed", { error: err.message });
    res.status(500).json({ error: err.message });
  }
});

app.get("/projects", authenticateOptional, async (req, res) => {
  try {
    const uc = req.userContext
      ? { ...req.userContext, role: resolveVaultRole(req.user) }
      : { role: "viewer-read" };
    const source  = await getActiveSource(uc);
    const allowed = getAllowedClassifications(source);
    const { rows } = await poolManager.query(
      `SELECT p.id, u.first_name, u.last_name, p.project_name, p.role,
              p.budget, p.start_date, p.status, p.classification
       FROM projects p
       JOIN users u ON u.id = p.user_id
       WHERE p.classification IN (${sqlInList(allowed)})
       ORDER BY p.start_date DESC, u.id`,
      [],
      uc,
    );
    res.json(rows);
  } catch (err) {
    if (err.code === "42501") return res.json([]);
    log.error("GET /projects failed", { error: err.message });
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Credentials — includes trust level, role scoping, and pool status
// ---------------------------------------------------------------------------
app.get("/credentials", authenticateOptional, async (req, res) => {
  try {
    const uc    = req.userContext
      ? { ...req.userContext, role: resolveVaultRole(req.user) }
      : undefined;
    const creds   = await connector.getCredentials(uc);
    const status  = poolManager.getStatus();
    const allowed = getAllowedClassifications(creds.source);
    const level   = TRUST_LEVELS[creds.source] ?? 0;

    res.json({
      source:                  creds.source,
      connector_phase:         connectorPhase,
      capabilities:            {
        ciba_write: connectorCapabilities.ciba_write === true,
      },
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
      requestedBy:             uc || null,
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

  const uc = req.userContext
    ? { ...req.userContext, role: resolveVaultRole(req.user) }
    : { role: "viewer-read" };

  try {
    const source  = await getActiveSource(uc);
    const allowed = getAllowedClassifications(source);
    const inList  = sqlInList(allowed);
    const datasets = selectAskDatasets(question);

    // Per-query permission guard: some DB roles (e.g. viewer-read) only have
    // GRANT on a subset of tables. Catch 42501 (permission denied) per-query
    // and return an empty result — the trust-level filter and GRANT work together.
    const safeQuery = async (sql, params) => {
      try {
        return await poolManager.query(sql, params, uc);
      } catch (err) {
        if (err.code === "42501") {
          log.info("/ask table access denied — role lacks GRANT", { role: uc.role, code: err.code });
          return { rows: [] };
        }
        throw err;
      }
    };

    const [users, orders, prefs, training, tickets, projects] = await Promise.all([
      safeQuery(
        "SELECT first_name, last_name, email, city, country, joined FROM users ORDER BY id",
        [],
      ),
      safeQuery(
        `SELECT u.first_name, o.item, o.category, o.quantity, o.price, o.ordered_at, o.classification
         FROM orders o JOIN users u ON u.id = o.user_id
         WHERE o.classification IN (${inList})
         ORDER BY u.id, o.ordered_at`,
        [],
      ),
      safeQuery(
        `SELECT u.first_name, p.category, p.value, p.classification
         FROM preferences p JOIN users u ON u.id = p.user_id
         WHERE p.classification IN (${inList})
         ORDER BY u.id, p.category`,
        [],
      ),
      safeQuery(
        `SELECT u.first_name, t.course, t.provider, t.completed_at, t.score, t.certified, t.classification
         FROM training t JOIN users u ON u.id = t.user_id
         WHERE t.classification IN (${inList})
         ORDER BY u.id, t.completed_at`,
        [],
      ),
      safeQuery(
        `SELECT u.first_name, t.title, t.system, t.priority, t.status, t.opened_at, t.classification
         FROM tickets t JOIN users u ON u.id = t.user_id
         WHERE t.classification IN (${inList})
         ORDER BY u.id, t.opened_at`,
        [],
      ),
      safeQuery(
        `SELECT u.first_name, p.project_name, p.role, p.budget, p.start_date, p.status, p.classification
         FROM projects p JOIN users u ON u.id = p.user_id
         WHERE p.classification IN (${inList})
         ORDER BY u.id, p.start_date`,
        [],
      ),
    ]);

    const fmt = (rows) => rows.map((r) => JSON.stringify(r)).join("\n");

    const sections = [];

    if (datasets.has("users")) {
      sections.push(`USERS:\n${fmt(users.rows)}`);
    }
    if (datasets.has("orders")) {
      sections.push(`ORDERS (visible at trust level — classifications: ${allowed.join(", ")}):\n${fmt(orders.rows)}`);
    }
    if (datasets.has("preferences")) {
      sections.push(`PREFERENCES (visible at trust level — classifications: ${allowed.join(", ")}):\n${fmt(prefs.rows)}`);
    }
    if (datasets.has("training")) {
      sections.push(`TRAINING (visible at trust level — classifications: ${allowed.join(", ")}):\n${fmt(training.rows)}`);
    }
    if (datasets.has("tickets")) {
      sections.push(`TICKETS (visible at trust level — classifications: ${allowed.join(", ")}):\n${fmt(tickets.rows)}`);
    }
    if (datasets.has("projects")) {
      sections.push(`PROJECTS (visible at trust level — classifications: ${allowed.join(", ")}):\n${fmt(projects.rows)}`);
    }

    const context = sections.join("\n\n").trim();

    const prompt = `You are a careful assistant with access to a user database.
Use only the data provided below to answer the question.
Do not invent, estimate, or assume any facts that are not explicitly present in the data.
Be concise and friendly, but prioritize correctness over fluency.
Note: some data may be hidden based on the current security level (${source}).

Rules:
- Use only the rows shown in the DATA section.
- Never infer missing values.
- For numeric comparisons such as highest, lowest, most, least, total, or ranking:
  compare the exact numeric values from the rows.
- Do not reinterpret numbers, add zeros, round values, or convert units unless the data explicitly says so.
- If a user has multiple rows, consider all of that user's rows before answering.
- When the answer depends on one specific row, include the exact row values that justify the answer.
- If the data is insufficient, say so explicitly.

--- DATA ---
${context}
--- END DATA ---

Question: ${question}
Answer:`;

    log.info("/ask", {
      user:
        req.user?.preferred_username ||
        req.user?.email ||
        req.user?.sub ||
        "anonymous",
      role: uc?.role || "none",
      source,
      datasets: [...datasets],
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
// Auth token proxy — exchanges username/password for a Keycloak JWT.
// The browser cannot reach Keycloak directly (net-data is Docker-internal),
// so the backend acts as a thin proxy. Returns only the access_token.
// ---------------------------------------------------------------------------
const KEYCLOAK_ADDR      = process.env.KEYCLOAK_ADDR      || "http://keycloak:8080";
const KEYCLOAK_REALM     = process.env.KEYCLOAK_REALM     || "zero-trust";
const KEYCLOAK_CLIENT_ID = process.env.KEYCLOAK_CLIENT_ID || "backend";


// ---------------------------------------------------------------------------
// CIBA — Delegated authority routes (dormant until called)
// ---------------------------------------------------------------------------
app.use("/ciba", cibaRoutes);



app.post("/auth/token", async (req, res) => {
  const { username, password } = req.body || {};
  if (!username || !password) {
    return res.status(400).json({ error: "username and password are required" });
  }

  try {
    const body = new URLSearchParams({
      grant_type:    "password",
      client_id:     KEYCLOAK_CLIENT_ID,
      client_secret: process.env.KEYCLOAK_CLIENT_SECRET || "",
      username,
      password,
      scope:         "openid",
    });

    const kcRes = await fetch(
      `${KEYCLOAK_ADDR}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token`,
      { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: body.toString() }
    );

    if (!kcRes.ok) {
      await kcRes.text();
      log.warn("User login failed", { username, status: kcRes.status });
      return res.status(401).json({ error: "Invalid credentials" });
    }

    const json = await kcRes.json();
    log.info("User token issued", { username, expires_in: json.expires_in });
    res.json({ access_token: json.access_token, expires_in: json.expires_in });
  } catch (err) {
    log.error("Keycloak proxy error", { error: err.message });
    res.status(502).json({ error: "Identity provider unreachable" });
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
