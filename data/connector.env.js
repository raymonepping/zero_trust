/**
 * connector.js — Environment-backed credential provider
 *
 * This file is volume-mounted into the container so you can swap it out
 * without rebuilding the image.
 *
 * Credential resolution order:
 *   1. Individual env vars: POSTGRES_DB_HOST, POSTGRES_DB_PORT, POSTGRES_DB,
 *      POSTGRES_USER, POSTGRES_PASSWORD
 *   2. DATABASE_URL (parsed) — used when individual vars are absent
 *   3. Hard-coded defaults (host: "db", database: "appdb", port: 5432)
 */
const fs   = require("fs");
const path = require("path");

function loadLocalEnv() {
  const envPath = path.join(__dirname, ".env");

  if (!fs.existsSync(envPath)) return;

  const lines = fs.readFileSync(envPath, "utf8").split("\n");
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;

    const separator = trimmed.indexOf("=");
    if (separator === -1) continue;

    const key   = trimmed.slice(0, separator).trim();
    const value = trimmed.slice(separator + 1).trim();

    if (!(key in process.env)) {
      process.env[key] = value;
    }
  }
}

function parseDatabaseUrl(url) {
  try {
    const u = new URL(url);
    return {
      host:     u.hostname              || "db",
      port:     parseInt(u.port, 10)   || 5432,
      database: u.pathname.slice(1)    || "appdb",
      user:     decodeURIComponent(u.username) || "appuser",
      password: decodeURIComponent(u.password) || "apppassword",
    };
  } catch {
    return null;
  }
}

loadLocalEnv();

async function getCredentials() {
  // Individual vars take precedence
  if (process.env.POSTGRES_USER && process.env.POSTGRES_PASSWORD) {
    return {
      host:     process.env.POSTGRES_DB_HOST || "db",
      port:     Number(process.env.POSTGRES_DB_PORT) || 5432,
      database: process.env.POSTGRES_DB     || "appdb",
      user:     process.env.POSTGRES_USER,
      password: process.env.POSTGRES_PASSWORD,
      source:   "env-file",
      path:     ".env (individual vars)",
    };
  }

  // Fall back to DATABASE_URL
  const fromUrl = process.env.DATABASE_URL && parseDatabaseUrl(process.env.DATABASE_URL);
  if (fromUrl) {
    return {
      ...fromUrl,
      source: "env-file",
      path:   ".env (DATABASE_URL)",
    };
  }

  // Last resort defaults
  return {
    host:     "db",
    port:     5432,
    database: "appdb",
    user:     "appuser",
    password: "apppassword",
    source:   "env-file",
    path:     ".env (defaults)",
  };
}

module.exports = { getCredentials };
