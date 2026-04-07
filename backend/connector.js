/**
 * connector.js — Environment-backed credential provider
 *
 * This file is volume-mounted into the container so you can swap it out
 * without rebuilding the image.
 */
const fs = require("fs");
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

    const key = trimmed.slice(0, separator).trim();
    const value = trimmed.slice(separator + 1).trim();

    if (!(key in process.env)) {
      process.env[key] = value;
    }
  }
}

loadLocalEnv();

async function getCredentials() {
  return {
    host: process.env.POSTGRES_DB_HOST || "postgres",
    port: Number(process.env.POSTGRES_DB_PORT) || 5432,
    database: process.env.POSTGRES_DB || "appdb",
    user: process.env.POSTGRES_USER || "appuser",
    password: process.env.POSTGRES_PASSWORD || "apppassword",
    source: "env-file",
    path: path.join(__dirname, ".env"),
  };
}

module.exports = { getCredentials };
