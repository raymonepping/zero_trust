/**
 * connector.js — Vault credential provider
 *
 * This file is volume-mounted into the container so you can swap it out
 * without rebuilding the image.
 *
 * Phase 1 (current): reads static credentials from Vault KV v2
 * Phase 2 (next):    replace getCredentials() body to use Vault dynamic
 *                    database secrets engine instead
 *
 * Vault KV secret expected at VAULT_KV_PATH (default: secret/data/postgres):
 *   vault kv put secret/postgres username=appuser password=apppassword host=db port=5432 database=appdb
 */

const VAULT_ADDR = process.env.VAULT_ADDR || "http://vault:8200";
const VAULT_TOKEN = process.env.VAULT_TOKEN;
const VAULT_KV_PATH = process.env.VAULT_KV_PATH || "secret/data/postgres";

async function getCredentials() {
  if (!VAULT_TOKEN) throw new Error("VAULT_TOKEN is not set");

  const res = await fetch(`${VAULT_ADDR}/v1/${VAULT_KV_PATH}`, {
    headers: { "X-Vault-Token": VAULT_TOKEN },
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Vault responded ${res.status}: ${body}`);
  }

  // KV v2 wraps the secret under data.data
  const json = await res.json();
  const secret = json.data?.data;

  if (!secret) throw new Error(`No data found at ${VAULT_KV_PATH}`);

  return {
    host: secret.host || "db",
    port: Number(secret.port) || 5432,
    database: secret.database || "appdb",
    user: secret.username,
    password: secret.password,
    source: "vault-kv",
    path: VAULT_KV_PATH,
  };
}

module.exports = { getCredentials };
