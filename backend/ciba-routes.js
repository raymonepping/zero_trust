/**
 * ciba-routes.js — Express routes for CIBA delegated authority
 *
 * Route groups:
 *
 *   AD handler (called by Keycloak):
 *     POST /ciba/request        — receives authentication delegation from Keycloak
 *
 *   Frontend-facing (called by Vite UI):
 *     POST /ciba/initiate       — start a CIBA flow for an elevated action
 *     GET  /ciba/pending        — list pending approval requests for the user
 *     POST /ciba/approve        — approve or deny a pending request
 *     GET  /ciba/status/:id     — poll for CIBA flow completion status
 *
 *   Write-gated action:
 *     POST /orders/:id/status   — update order status (requires completed CIBA flow)
 */

"use strict";

const { Router }     = require("express");
const ciba           = require("./ciba");
const connector      = require("./connector");
const poolManager    = require("./pool-manager");
const log            = require("./logger");
const { authenticate } = require("./auth");
const { resolveVaultRole } = require("./roleResolver");

const router = Router();

function cibaWriteEnabled() {
  return connector.CAPABILITIES?.ciba_write === true;
}

function requireCibaConnector(req, res, next) {
  if (!cibaWriteEnabled()) {
    return res.status(404).json({
      error: "CIBA write flow is not enabled for the active connector",
    });
  }
  next();
}

// ---------------------------------------------------------------------------
// In-flight CIBA sessions — tracks initiate→poll→write lifecycle
//
// Map<sessionId, {
//   authReqId, userId, userEmail, action, orderId, newStatus,
//   status,         // "polling" | "approved" | "denied" | "expired" | "executed"
//   pollPromise,    // the running pollForApproval promise
//   cibaTokens,     // { accessToken, ... } after approval
//   createdAt,
// }>
// ---------------------------------------------------------------------------

const cibaSessions = new Map();
let sessionCounter = 0;

// Cleanup old sessions every 5 minutes
setInterval(() => {
  const cutoff = Date.now() - 10 * 60_000;
  for (const [id, session] of cibaSessions) {
    if (session.createdAt < cutoff) cibaSessions.delete(id);
  }
}, 5 * 60_000).unref();

// ---------------------------------------------------------------------------
// AD Handler — Keycloak delegates authentication here
// ---------------------------------------------------------------------------

/**
 * POST /ciba/request
 *
 * Called by Keycloak's HTTP Authentication Channel Provider.
 * Must respond 201 to acknowledge, otherwise Keycloak returns 503 to the initiator.
 *
 * Body (from Keycloak):
 *   { login_hint, scope, binding_message, is_consent_required }
 *
 * Authorization header contains Keycloak's delegation bearer token.
 */
router.post("/request", (req, res) => {
  try {
    const bearerToken = req.headers.authorization?.replace("Bearer ", "");

    if (!bearerToken) {
      log.warn("CIBA /request: Missing bearer token from Keycloak");
      return res.status(401).json({ error: "Missing authorization" });
    }

    ciba.handleDelegation(req.body, bearerToken);

    // Keycloak requires 201 to confirm receipt
    res.status(201).json({ status: "received" });
  } catch (err) {
    log.error("CIBA /request error", { error: err.message });
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Initiate — frontend starts a CIBA flow for an elevated action
// ---------------------------------------------------------------------------

/**
 * POST /ciba/initiate
 *
 * Body:
 *   { orderId: 42, newStatus: "shipped" }
 *
 * Requires a valid user JWT (authenticate middleware).
 * The binding_message describes the action for the approval UI.
 */
router.post("/initiate", authenticate, requireCibaConnector, async (req, res) => {
  const { orderId, newStatus } = req.body || {};

  if (!orderId || !newStatus) {
    return res.status(400).json({ error: "orderId and newStatus are required" });
  }

  const validStatuses = ["processing", "shipped", "delivered", "cancelled"];
  if (!validStatuses.includes(newStatus)) {
    return res.status(400).json({
      error: `Invalid status. Must be one of: ${validStatuses.join(", ")}`,
    });
  }

  const username = req.user?.preferred_username || req.user?.email || req.userContext?.email;
  if (!username) {
    return res.status(400).json({ error: "Cannot determine username from JWT for CIBA login_hint" });
  }

  // Keycloak CIBA requires a short, basic plain-text binding message without spaces.
  const bindingMessage = `order-${orderId}-status-${newStatus}`;

  try {
    const { authReqId, expiresIn, interval } = await ciba.initiate({
      loginHint:      username,
      bindingMessage,
      initiatedBy:    { sub: req.userContext.sub, email: req.userContext.email },
      action:         bindingMessage,
    });

    // Create a session to track this CIBA flow
    const sessionId = `ciba-${++sessionCounter}-${Date.now()}`;

    const session = {
      authReqId,
      userId:     req.userContext.sub,
      userEmail:  req.userContext.email,
      action:     bindingMessage,
      orderId,
      newStatus,
      status:     "polling",
      pollPromise: null,
      cibaTokens:  null,
      createdAt:   Date.now(),
    };

    cibaSessions.set(sessionId, session);

    // Start polling in the background — do not block the response
    session.pollPromise = ciba.pollForApproval(authReqId, { interval })
      .then((tokens) => {
        session.status     = "approved";
        session.cibaTokens = tokens;
        log.info("CIBA session approved", { session_id: sessionId, user: username });
      })
      .catch((err) => {
        session.status = err.message.includes("denied") ? "denied" : "expired";
        log.warn("CIBA session failed", { session_id: sessionId, error: err.message });
      });

    log.info("CIBA session created", {
      session_id:  sessionId,
      user:        username,
      action:      bindingMessage,
      expires_in:  expiresIn,
    });
    log.debug("CIBA session auth request id", { session_id: sessionId, auth_req_id: authReqId });

    res.json({
      sessionId,
      authReqId,
      expiresIn,
      interval,
      action: bindingMessage,
    });
  } catch (err) {
    log.error("CIBA initiate failed", { error: err.message });
    res.status(502).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Pending — frontend polls for approval requests to show the dialog
// ---------------------------------------------------------------------------

/**
 * GET /ciba/pending
 *
 * Returns pending CIBA delegation requests for the authenticated user.
 * The frontend polls this to show the approval dialog.
 */
router.get("/pending", authenticate, requireCibaConnector, (req, res) => {
  const username = req.user?.preferred_username || req.user?.email || req.userContext?.email;
  const pending  = ciba.getPending(username);
  res.json(pending);
});

// ---------------------------------------------------------------------------
// Approve / Deny — user makes their decision
// ---------------------------------------------------------------------------

/**
 * POST /ciba/approve
 *
 * Body:
 *   { requestId: "...", decision: "SUCCEED" | "CANCELLED" }
 *
 * The requestId comes from GET /ciba/pending.
 */
router.post("/approve", authenticate, requireCibaConnector, async (req, res) => {
  const { requestId, decision } = req.body || {};

  if (!requestId || !decision) {
    return res.status(400).json({ error: "requestId and decision are required" });
  }

  try {
    await ciba.resolve(requestId, decision);

    log.info("CIBA approval processed", {
      decision,
      user: req.user?.preferred_username || req.userContext?.sub,
    });
    log.debug("CIBA approval request id", {
      request_id: requestId,
      decision,
      user: req.user?.preferred_username || req.userContext?.sub,
    });

    res.json({ status: "callback_sent", decision });
  } catch (err) {
    log.error("CIBA approve failed", { error: err.message });
    res.status(400).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Status — frontend polls for CIBA session completion
// ---------------------------------------------------------------------------

/**
 * GET /ciba/status/:sessionId
 *
 * Returns the current status of a CIBA session.
 * The frontend polls this after calling /ciba/initiate.
 */
router.get("/status/:sessionId", authenticate, requireCibaConnector, (req, res) => {
  const session = cibaSessions.get(req.params.sessionId);

  if (!session) {
    return res.status(404).json({ error: "CIBA session not found" });
  }

  // Only the initiating user can check status
  if (session.userId !== req.userContext.sub) {
    return res.status(403).json({ error: "Not your CIBA session" });
  }

  res.json({
    sessionId: req.params.sessionId,
    status:    session.status,
    action:    session.action,
    orderId:   session.orderId,
    newStatus: session.newStatus,
    age:       Math.round((Date.now() - session.createdAt) / 1000),
  });
});

// ---------------------------------------------------------------------------
// Write-gated action — execute the order update after CIBA approval
// ---------------------------------------------------------------------------

/**
 * POST /orders/:id/status
 *
 * Body:
 *   { newStatus: "shipped", cibaSessionId: "ciba-1-..." }
 *
 * Requires:
 *   1. Valid user JWT (authenticate)
 *   2. Completed CIBA session in "approved" state
 *   3. Session action matches the requested update
 *   4. Write-scoped Vault credential (support-write)
 */
router.post("/orders/:id/status", authenticate, requireCibaConnector, async (req, res) => {
  const orderId    = parseInt(req.params.id, 10);
  const { newStatus, cibaSessionId } = req.body || {};

  if (!newStatus || !cibaSessionId) {
    return res.status(400).json({ error: "newStatus and cibaSessionId are required" });
  }

  // Validate CIBA session
  const session = cibaSessions.get(cibaSessionId);

  if (!session) {
    return res.status(404).json({ error: "CIBA session not found" });
  }

  if (session.userId !== req.userContext.sub) {
    return res.status(403).json({ error: "CIBA session belongs to a different user" });
  }

  if (session.status !== "approved") {
    return res.status(403).json({
      error: `CIBA session not approved (current status: ${session.status})`,
    });
  }

  if (session.orderId !== orderId || session.newStatus !== newStatus) {
    return res.status(403).json({
      error: "CIBA session does not match the requested action",
    });
  }

  try {
    // Fetch write-scoped credential from Vault
    const writeCreds = await connector.getWriteCredentials(req.userContext);

    // Execute the UPDATE using a direct connection with write credentials
    const { Pool } = require("pg");
    const writePool = new Pool({
      host:     writeCreds.host,
      port:     writeCreds.port,
      database: writeCreds.database,
      user:     writeCreds.user,
      password: writeCreds.password,
      max:      1,
      connectionTimeoutMillis: 5000,
    });

    try {
      const result = await writePool.query(
        "UPDATE orders SET status = $1 WHERE id = $2 RETURNING id, status",
        [newStatus, orderId]
      );

      if (result.rowCount === 0) {
        return res.status(404).json({ error: `Order ${orderId} not found` });
      }

      session.status = "executed";

      log.info("CIBA: Write executed", {
        order_id:        orderId,
        new_status:      newStatus,
        ciba_session:    cibaSessionId,
        user:            req.userContext.sub,
        write_credential: writeCreds.user,
        lease_id:        writeCreds.leaseId,
      });

      // Revoke write credential immediately after use
      if (writeCreds.leaseId) {
        connector.revokeLease(writeCreds.leaseId).catch((err) => {
          log.warn("Write lease revoke failed", { lease_id: writeCreds.leaseId, error: err.message });
        });
      }

      res.json({
        success:  true,
        orderId:  result.rows[0].id,
        status:   result.rows[0].status,
        cibaSession: cibaSessionId,
        writeUser:   writeCreds.user,
        message:  `Order ${orderId} updated to '${newStatus}' via delegated authority`,
      });
    } finally {
      await writePool.end().catch(() => {});
    }
  } catch (err) {
    log.error("CIBA write execution failed", {
      order_id: orderId,
      error:    err.message,
      session:  cibaSessionId,
    });
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------
router.get("/diagnostics", (req, res) => {
  const cibaStatus = ciba.getStatus();
  const sessions   = {};

  for (const [id, s] of cibaSessions) {
    sessions[id] = {
      status:    s.status,
      action:    s.action,
      userId:    s.userId,
      age:       Math.round((Date.now() - s.createdAt) / 1000),
    };
  }

  res.json({
    enabled: cibaWriteEnabled(),
    ciba: cibaStatus,
    sessions,
  });
});

module.exports = router;
