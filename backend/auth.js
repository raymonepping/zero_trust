/**
 * auth.js — End-user JWT authentication middleware
 *
 * Verifies the Bearer token from incoming HTTP requests and attaches
 * the user's identity and role to req.userContext.
 *
 * This is SEPARATE from the connector's Keycloak flow:
 *   - connector.js authenticates the BACKEND to Vault (machine identity)
 *   - auth.js authenticates the END USER to the backend (user identity)
 *
 * req.userContext = {
 *   sub:   "user-uuid-123",      // JWT subject (who)
 *   role:  "support",            // JWT role claim (drives Vault DB role selection)
 *   email: "ray@example.com",    // For logging only
 * }
 *
 * Environment variables:
 *   JWT_SECRET  — HMAC secret for HS256 (dev)
 *   JWKS_URL    — JWKS endpoint for RS256 (production, e.g. Keycloak)
 *   JWT_ISSUER  — Expected issuer claim (optional validation)
 */

"use strict";

const JWT_SECRET = process.env.JWT_SECRET;
const JWKS_URL   = process.env.JWKS_URL;
const JWT_ISSUER = process.env.JWT_ISSUER || undefined;

let verifyJwt;

// ---------------------------------------------------------------------------
// Verifier initialization (lazy, runs once)
// ---------------------------------------------------------------------------

async function getVerifier() {
  if (verifyJwt) return verifyJwt;

  const jose = require("jose");

  if (JWKS_URL) {
    // RS256 / JWKS — production pattern (Keycloak, Auth0, etc.)
    const jwks = jose.createRemoteJWKSet(new URL(JWKS_URL));
    verifyJwt = async (token) => {
      const { payload } = await jose.jwtVerify(token, jwks, { issuer: JWT_ISSUER });
      return payload;
    };
  } else if (JWT_SECRET) {
    // HS256 — development and testing
    const secret = new TextEncoder().encode(JWT_SECRET);
    verifyJwt = async (token) => {
      const { payload } = await jose.jwtVerify(token, secret, { issuer: JWT_ISSUER });
      return payload;
    };
  } else {
    throw new Error("JWT_SECRET or JWKS_URL must be set for user authentication");
  }

  return verifyJwt;
}

// ---------------------------------------------------------------------------
// Role extraction (handles common JWT claim structures)
// ---------------------------------------------------------------------------

function extractRole(payload) {
  // Direct role claim
  if (typeof payload.role === "string") return payload.role;

  // Keycloak realm_access.roles
  if (Array.isArray(payload.realm_access?.roles)) {
    const prioritized = ["admin", "support", "viewer"];
    for (const role of prioritized) {
      if (payload.realm_access.roles.includes(role)) return role;
    }
  }

  // Generic roles array
  if (Array.isArray(payload.roles)) {
    const prioritized = ["admin", "support", "viewer"];
    for (const role of prioritized) {
      if (payload.roles.includes(role)) return role;
    }
  }

  return undefined;
}

// ---------------------------------------------------------------------------
// Middleware: required authentication
// ---------------------------------------------------------------------------

async function authenticate(req, res, next) {
  const authHeader = req.headers.authorization;

  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Missing or malformed Authorization header" });
  }

  try {
    const verify  = await getVerifier();
    const payload = await verify(authHeader.slice(7));
    const role    = extractRole(payload);

    req.userContext = {
      sub:   payload.sub,
      role,
      email: payload.email || payload.preferred_username || undefined,
    };

    next();
  } catch (err) {
    console.warn(`[auth] JWT verification failed: ${err.message}`);
    return res.status(401).json({ error: "Invalid or expired token" });
  }
}

// ---------------------------------------------------------------------------
// Middleware: optional authentication
// If valid JWT present, attaches userContext. If not, continues without.
// Connector falls back to default Vault role (or static mode).
// ---------------------------------------------------------------------------

async function authenticateOptional(req, res, next) {
  const authHeader = req.headers.authorization;

  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    req.userContext = undefined;
    return next();
  }

  try {
    const verify  = await getVerifier();
    const payload = await verify(authHeader.slice(7));
    const role    = extractRole(payload);

    req.userContext = {
      sub:   payload.sub,
      role,
      email: payload.email || payload.preferred_username || undefined,
    };
  } catch {
    req.userContext = undefined;
  }

  next();
}

module.exports = { authenticate, authenticateOptional };
