/**
 * ciba.js — Client Initiated Backchannel Authentication flow manager
 *
 * Manages the full CIBA lifecycle:
 *
 *   1. Backend initiates backchannel auth request with Keycloak
 *   2. Keycloak delegates to the AD handler (POST /ciba/request)
 *   3. AD handler stores the pending request for frontend polling
 *   4. User approves or denies via frontend
 *   5. AD handler sends callback to Keycloak with the decision
 *   6. Backend polls Keycloak token endpoint until approval or expiry
 *   7. On approval, the CIBA token can be used to obtain write credentials
 *
 * This module is stateless across restarts. Pending CIBA requests live
 * in memory and expire naturally (Keycloak enforces the TTL).
 */

"use strict";

const log = require("./logger");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const KEYCLOAK_ADDR      = process.env.KEYCLOAK_ADDR      || "http://keycloak:8080";
const KEYCLOAK_REALM     = process.env.KEYCLOAK_REALM     || "zero-trust";
const KEYCLOAK_CLIENT_ID = process.env.KEYCLOAK_CLIENT_ID || "backend";
const KEYCLOAK_CLIENT_SECRET = process.env.KEYCLOAK_CLIENT_SECRET;

const CIBA_POLL_INTERVAL_MS = parseInt(process.env.CIBA_POLL_INTERVAL || "5000", 10);
const CIBA_TIMEOUT_MS       = parseInt(process.env.CIBA_TIMEOUT || "120000", 10);

const TOKEN_ENDPOINT    = `${KEYCLOAK_ADDR}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token`;
const CIBA_AUTH_ENDPOINT = `${KEYCLOAK_ADDR}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/ext/ciba/auth`;
const CIBA_CALLBACK_ENDPOINT = `${KEYCLOAK_ADDR}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/ext/ciba/auth/callback`;

// ---------------------------------------------------------------------------
// Pending request store
//
// Map<auth_req_id, {
//   loginHint, scope, bindingMessage, isConsentRequired,
//   bearerToken,    // Keycloak's delegation bearer — needed for callback
//   status,         // "pending" | "approved" | "denied" | "expired"
//   createdAt,
//   resolvedAt,
//   initiatedBy,    // { sub, email } of the user who triggered the action
//   action,         // description of what is being authorized
// }>
// ---------------------------------------------------------------------------

const pendingRequests = new Map();

// Cleanup expired requests every 60 seconds
setInterval(() => {
  const now = Date.now();
  for (const [id, req] of pendingRequests) {
    if (now - req.createdAt > CIBA_TIMEOUT_MS + 30_000) {
      pendingRequests.delete(id);
    }
  }
}, 60_000).unref();

// ---------------------------------------------------------------------------
// Step 1 — Initiate CIBA request with Keycloak
// ---------------------------------------------------------------------------

/**
 * Starts a CIBA flow for an elevated action.
 *
 * @param {object} options
 * @param {string} options.loginHint      — username to authenticate (from req.user)
 * @param {string} options.bindingMessage — human-readable action description
 * @param {string} [options.scope]        — OAuth scope (default: "openid")
 * @param {object} [options.initiatedBy]  — { sub, email } of the requesting user
 * @param {string} [options.action]       — description for audit trail
 * @returns {Promise<{ authReqId, expiresIn, interval }>}
 */
async function initiate({ loginHint, bindingMessage, scope, initiatedBy, action }) {
  if (!KEYCLOAK_CLIENT_SECRET) {
    throw new Error("KEYCLOAK_CLIENT_SECRET is required for CIBA");
  }

  const body = new URLSearchParams({
    client_id:       KEYCLOAK_CLIENT_ID,
    client_secret:   KEYCLOAK_CLIENT_SECRET,
    login_hint:      loginHint,
    scope:           scope || "openid",
    binding_message: bindingMessage,
  });

  log.info("CIBA: Initiating backchannel auth", {
    login_hint: loginHint,
    binding_message: bindingMessage,
    initiated_by: initiatedBy?.sub || "unknown",
    action,
  });

  const res = await fetch(CIBA_AUTH_ENDPOINT, {
    method:  "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body:    body.toString(),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`CIBA initiate failed ${res.status}: ${text}`);
  }

  const json = await res.json();

  const authReqId = json.auth_req_id;
  const expiresIn = json.expires_in || 120;
  const interval  = json.interval   || 5;

  if (!authReqId) {
    throw new Error("CIBA initiate did not return auth_req_id");
  }

  log.info("CIBA: Auth request created", { expires_in: expiresIn, interval });
  log.debug("CIBA: Auth request id", { auth_req_id: authReqId });

  return { authReqId, expiresIn, interval };
}

// ---------------------------------------------------------------------------
// Step 2 — Handle AD delegation from Keycloak (POST /ciba/request)
// ---------------------------------------------------------------------------

/**
 * Called by Keycloak's HTTP Authentication Channel Provider.
 * Keycloak POSTs here when a CIBA request needs user authentication.
 *
 * The bearer token in the Authorization header is Keycloak's delegation
 * token — we store it and use it later to send the callback.
 *
 * @param {object} delegationBody — { login_hint, scope, binding_message, is_consent_required }
 * @param {string} bearerToken    — from Keycloak's Authorization header
 */
function handleDelegation(delegationBody, bearerToken) {
  // Keycloak does not include auth_req_id in the delegation body.
  // We use the bearer token as the lookup key since it is unique per request.
  const id = bearerToken;

  const pending = {
    loginHint:          delegationBody.login_hint,
    scope:              delegationBody.scope,
    bindingMessage:     delegationBody.binding_message,
    isConsentRequired:  delegationBody.is_consent_required,
    bearerToken,
    status:             "pending",
    createdAt:          Date.now(),
    resolvedAt:         null,
  };

  pendingRequests.set(id, pending);

  log.info("CIBA: AD delegation received", {
    login_hint:      pending.loginHint,
    binding_message: pending.bindingMessage,
    consent_required: pending.isConsentRequired,
  });
}

// ---------------------------------------------------------------------------
// Step 3 — Frontend queries pending approvals
// ---------------------------------------------------------------------------

/**
 * Returns all pending CIBA requests for a given user.
 *
 * @param {string} [loginHint] — filter by username (optional)
 * @returns {Array<{ id, loginHint, bindingMessage, scope, createdAt }>}
 */
function getPending(loginHint) {
  const result = [];

  for (const [id, req] of pendingRequests) {
    if (req.status !== "pending") continue;
    if (loginHint && req.loginHint !== loginHint) continue;

    result.push({
      id,
      loginHint:      req.loginHint,
      bindingMessage: req.bindingMessage,
      scope:          req.scope,
      createdAt:      req.createdAt,
      age:            Math.round((Date.now() - req.createdAt) / 1000),
    });
  }

  return result;
}

// ---------------------------------------------------------------------------
// Step 4 — User approves or denies
// ---------------------------------------------------------------------------

/**
 * Sends the user's decision back to Keycloak via the callback endpoint.
 *
 * @param {string} requestId — the pending request ID (bearer token)
 * @param {string} decision  — "SUCCEED" | "UNAUTHORIZED" | "CANCELLED"
 */
async function resolve(requestId, decision) {
  const pending = pendingRequests.get(requestId);

  if (!pending) {
    throw new Error("CIBA request not found or already resolved");
  }

  if (pending.status !== "pending") {
    throw new Error(`CIBA request already resolved: ${pending.status}`);
  }

  const validDecisions = ["SUCCEED", "UNAUTHORIZED", "CANCELLED"];
  if (!validDecisions.includes(decision)) {
    throw new Error(`Invalid decision: ${decision}. Must be one of: ${validDecisions.join(", ")}`);
  }

  log.info("CIBA: Sending callback to Keycloak", {
    login_hint: pending.loginHint,
    decision,
  });

  const res = await fetch(CIBA_CALLBACK_ENDPOINT, {
    method:  "POST",
    headers: {
      "Content-Type":  "application/json",
      "Authorization": `Bearer ${pending.bearerToken}`,
    },
    body: JSON.stringify({ status: decision }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`CIBA callback failed ${res.status}: ${text}`);
  }

  pending.status     = decision === "SUCCEED" ? "approved" : "denied";
  pending.resolvedAt = Date.now();

  log.info("CIBA: Callback accepted", {
    login_hint: pending.loginHint,
    decision,
    status:     pending.status,
  });
}

// ---------------------------------------------------------------------------
// Step 5 — Poll Keycloak token endpoint for CIBA grant
// ---------------------------------------------------------------------------

/**
 * Polls the Keycloak token endpoint until the CIBA request is approved,
 * denied, or expires. Returns the token set on success.
 *
 * @param {string} authReqId — from the initiate() response
 * @param {object} [options]
 * @param {number} [options.interval] — poll interval in seconds (default: 5)
 * @param {number} [options.timeout]  — max wait in ms (default: CIBA_TIMEOUT_MS)
 * @returns {Promise<{ accessToken, refreshToken, idToken, expiresIn }>}
 */
async function pollForApproval(authReqId, options = {}) {
  const intervalMs = (options.interval || 5) * 1000;
  const timeout    = options.timeout || CIBA_TIMEOUT_MS;
  const startedAt  = Date.now();

  log.debug("CIBA: Polling started", { auth_req_id: authReqId });

  while (Date.now() - startedAt < timeout) {
    await sleep(intervalMs);

    const body = new URLSearchParams({
      grant_type:    "urn:openid:params:grant-type:ciba",
      auth_req_id:   authReqId,
      client_id:     KEYCLOAK_CLIENT_ID,
      client_secret: KEYCLOAK_CLIENT_SECRET,
    });

    const res = await fetch(TOKEN_ENDPOINT, {
      method:  "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body:    body.toString(),
    });

    if (res.ok) {
      const json = await res.json();

      log.info("CIBA: Approval received, tokens issued", { expires_in: json.expires_in });
      log.debug("CIBA: Approved auth request id", { auth_req_id: authReqId });

      return {
        accessToken:  json.access_token,
        refreshToken: json.refresh_token,
        idToken:      json.id_token,
        expiresIn:    json.expires_in,
      };
    }

    const errorBody = await res.json().catch(() => ({}));
    const error     = errorBody.error;

    if (error === "authorization_pending") {
      log.debug("CIBA: Still pending", { auth_req_id: authReqId });
      continue;
    }

    if (error === "slow_down") {
      log.debug("CIBA: Slow down, adding 5s", { auth_req_id: authReqId });
      await sleep(5000);
      continue;
    }

    if (error === "expired_token") {
      throw new Error("CIBA request expired — user did not respond in time");
    }

    if (error === "access_denied") {
      throw new Error("CIBA request denied by user");
    }

    throw new Error(`CIBA poll error: ${error || res.status} — ${errorBody.error_description || ""}`);
  }

  throw new Error("CIBA request timed out waiting for approval");
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Returns a summary of all pending/resolved requests for diagnostics.
 */
function getStatus() {
  const summary = { pending: 0, approved: 0, denied: 0, expired: 0, total: pendingRequests.size };

  for (const [, req] of pendingRequests) {
    if (req.status === "pending" && Date.now() - req.createdAt > CIBA_TIMEOUT_MS) {
      summary.expired++;
    } else {
      summary[req.status] = (summary[req.status] || 0) + 1;
    }
  }

  return summary;
}

module.exports = {
  initiate,
  handleDelegation,
  getPending,
  resolve,
  pollForApproval,
  getStatus,
};
