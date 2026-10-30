/** Vault Agent file delivery. This connector never authenticates or calls Vault. */
"use strict";
const fs = require("node:fs/promises");
const filename = process.env.VAULT_AGENT_CREDS_FILE || "/vault/secrets/db-creds.json";
const listeners = [];
const observedPoolRoles = new Set(["viewer-read"]);
let timer;
let previous;
async function getCredentials(userContext) {
  observedPoolRoles.add(userContext?.role || "viewer-read");
  const data = JSON.parse(await fs.readFile(filename, "utf8"));
  if (!data.username || !data.password || !data.lease_id) throw new Error("Incomplete Agent credential file");
  return {
    host: data.host || "db", port: Number(data.port || 5432), database: data.database || "appdb",
    user: data.username, password: data.password, source: "vault-agent-dynamic",
    path: filename, leaseId: data.lease_id, ttl: data.lease_duration,
    issuedFor: "vault-agent",
  };
}
function onRotation(callback) { listeners.push(callback); }
async function startAutoRenewal() {
  previous = await getCredentials();
  if (timer) return previous;
  // Agent owns renewal/reissuance. Observe atomic file replacement only.
  timer = setInterval(async () => {
    try {
      const next = await getCredentials();
      if (next.leaseId !== previous.leaseId || next.password !== previous.password) {
        previous = next;
        for (const poolRole of observedPoolRoles) {
          for (const callback of listeners) callback(poolRole, next);
        }
      }
    } catch { /* Preserve current pool while Agent retries; future reads fail visibly. */ }
  }, 1000);
  timer.unref();
  return previous;
}
function stopAutoRenewal() { clearInterval(timer); timer = undefined; }
module.exports = { MODE: "agent", CONNECTOR_PHASE: "agent-dynamic", getCredentials,
  onRotation, startAutoRenewal, stopAutoRenewal };
