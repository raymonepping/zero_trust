const express     = require("express");
const poolManager = require("./pool-manager");

const app  = express();
const PORT = process.env.PORT || 3000;
const OLLAMA_ADDR = process.env.OLLAMA_ADDR || "http://ollama:11434";

app.use(express.json());

// ---------------------------------------------------------------------------
// Trust level — derived from the active connector's source field
//
// Level 0 (public)                  — static-config, env-file
// Level 1 (internal)                — vault-kv, vault-dynamic
// Level 2 (confidential)            — vault-approle, vault-approle-dynamic
// Level 3 (restricted — full trust) — vault-jwt-dynamic
// ---------------------------------------------------------------------------

const TRUST_LEVELS = {
  "static-config":        0,
  "env-file":             0,
  "vault-kv":             1,
  "vault-dynamic":        1,
  "vault-approle":        2,
  "vault-approle-dynamic": 2,
  "vault-jwt-dynamic":    3,
};

const CLASSIFICATIONS = ["public", "internal", "confidential", "restricted"];

function getAllowedClassifications(source) {
  const level = TRUST_LEVELS[source] ?? 0;
  return CLASSIFICATIONS.slice(0, level + 1);
}

async function getActiveSource() {
  try {
    const connector = require("./connector");
    const creds = await connector.getCredentials();
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
    // Vault /v1/sys/health returns 200 (active), 429 (standby), 472/473 (DR),
    // 501 (not initialised), 503 (sealed) — all non-2xx but still reachable.
    // We pass ?standbyok=true so standby nodes also return 200.
    const res = await fetch(
      `${VAULT_ADDR}/v1/sys/health?standbyok=true&perfstandbyok=true`,
      { signal: AbortSignal.timeout(3000) }
    );
    const json = await res.json().catch(() => ({}));
    const reachable = res.status !== 503 && res.status !== 501;
    if (!reachable) {
      const msg = json.errors?.[0] || (res.status === 503 ? "sealed" : "not initialised");
      console.error(`[server] Vault health degraded: ${msg} (HTTP ${res.status})`);
      return { ok: false, status: msg, sealed: res.status === 503, version: json.version || null };
    }
    return { ok: true, status: "active", sealed: false, version: json.version || null };
  } catch (err) {
    console.error(`[server] Vault health error: ${err.message}`);
    return { ok: false, status: err.message, sealed: null, version: null };
  }
}

// ---------------------------------------------------------------------------
// Health
// ---------------------------------------------------------------------------
app.get("/", async (req, res) => {
  try {
    await poolManager.query("SELECT 1");
    res.json({ status: "ok", message: "database is connected" });
  } catch (err) {
    res.status(500).json({ status: "error", message: err.message });
  }
});

app.get("/health", async (req, res) => {
  const [dbResult, vaultResult] = await Promise.allSettled([
    poolManager.query("SELECT 1"),
    probeVault(),
  ]);

  const dbOk    = dbResult.status === "fulfilled";
  const vaultOk = vaultResult.status === "fulfilled" && vaultResult.value.ok;
  const vault   = vaultResult.status === "fulfilled" ? vaultResult.value : { ok: false, status: "probe failed" };

  const overall = dbOk && vaultOk ? "ok" : "degraded";
  const httpStatus = dbOk ? 200 : 503;  // 503 only if DB is down (app non-functional)

  if (!vaultOk) {
    console.error(`[server] Health check: Vault degraded — ${vault.status}`);
  }

  res.status(httpStatus).json({
    status:  overall,
    db:      dbOk    ? "connected" : dbResult.reason?.message || "error",
    vault: {
      status:  vault.status,
      ok:      vault.ok,
      sealed:  vault.sealed ?? null,
      version: vault.version || null,
    },
  });
});

// ---------------------------------------------------------------------------
// Data APIs — filtered by trust level
// ---------------------------------------------------------------------------
app.get("/users", async (req, res) => {
  try {
    const { rows } = await poolManager.query(
      "SELECT id, first_name, last_name, email, city, country, joined FROM users ORDER BY id",
    );
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get("/orders", async (req, res) => {
  try {
    const source  = await getActiveSource();
    const allowed = getAllowedClassifications(source);
    const { rows } = await poolManager.query(`
      SELECT o.id, u.first_name, u.last_name, o.item, o.category,
             o.quantity, o.price, o.ordered_at, o.classification
      FROM orders o
      JOIN users u ON u.id = o.user_id
      WHERE o.classification IN (${sqlInList(allowed)})
      ORDER BY o.ordered_at DESC
    `);
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get("/preferences", async (req, res) => {
  try {
    const source  = await getActiveSource();
    const allowed = getAllowedClassifications(source);
    const { rows } = await poolManager.query(`
      SELECT p.id, u.first_name, u.last_name, p.category, p.value, p.classification
      FROM preferences p
      JOIN users u ON u.id = p.user_id
      WHERE p.classification IN (${sqlInList(allowed)})
      ORDER BY u.id, p.category
    `);
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Credentials — includes trust level and classification access
// ---------------------------------------------------------------------------
app.get("/credentials", async (req, res) => {
  try {
    const connector = require("./connector");
    const creds     = await connector.getCredentials();
    const status    = poolManager.getStatus();
    const allowed   = getAllowedClassifications(creds.source);
    const level     = TRUST_LEVELS[creds.source] ?? 0;

    res.json({
      source:                  creds.source,
      path:                    creds.path    || null,
      host:                    creds.host,
      port:                    creds.port,
      database:                creds.database,
      username:                creds.user,
      password:                "***",
      ttl:                     creds.ttl     || null,
      leaseId:                 creds.leaseId || null,
      trust_level:             level,
      allowed_classifications: allowed,
      pool:                    status.pool,
      lease:                   status.lease,
      rotations:               status.rotationCount,
    });
  } catch (err) {
    res.status(502).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Lease health — current lease status and rotation state
// ---------------------------------------------------------------------------
app.get("/health/lease", (_req, res) => {
  try {
    const connector = require("./connector");
    const status    = poolManager.getStatus();
    const lease     = typeof connector.getLeaseInfo === "function"
      ? connector.getLeaseInfo()
      : { status: "not-supported", leaseId: null, ttl: null };

    res.json({
      lease_id:             lease.leaseId   || null,
      ttl:                  lease.ttl        || null,
      remaining_sec:        lease.remainingSec ?? null,
      status:               lease.status     || "unknown",
      rotation_in_progress: status.rotationActive,
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Ask — context filtered by trust level
// ---------------------------------------------------------------------------
app.post("/ask", async (req, res) => {
  const { question } = req.body;
  if (!question) return res.status(400).json({ error: "question is required" });

  try {
    const source  = await getActiveSource();
    const allowed = getAllowedClassifications(source);
    const inList  = sqlInList(allowed);

    const [users, orders, prefs] = await Promise.all([
      poolManager.query(
        "SELECT first_name, last_name, email, city, country, joined FROM users ORDER BY id",
      ),
      poolManager.query(`
        SELECT u.first_name, o.item, o.category, o.quantity, o.price, o.ordered_at, o.classification
        FROM orders o JOIN users u ON u.id = o.user_id
        WHERE o.classification IN (${inList})
        ORDER BY u.id, o.ordered_at
      `),
      poolManager.query(`
        SELECT u.first_name, p.category, p.value, p.classification
        FROM preferences p JOIN users u ON u.id = p.user_id
        WHERE p.classification IN (${inList})
        ORDER BY u.id, p.category
      `),
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
      const lines = decoder
        .decode(value, { stream: true })
        .split("\n")
        .filter(Boolean);
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
  console.log(`[server] ${signal} received — shutting down...`);
  await poolManager.shutdown();
  process.exit(0);
}

process.on("SIGTERM", () => gracefulShutdown("SIGTERM"));
process.on("SIGINT",  () => gracefulShutdown("SIGINT"));

async function start() {
  await poolManager.initialize();
  app.listen(PORT, () => {
    console.log(`[server] Backend listening on port ${PORT}`);
    console.log(`[server] Ollama: ${OLLAMA_ADDR}`);
  });
}

start().catch((err) => {
  console.error("[server] Failed to start:", err.message);
  process.exit(1);
});
