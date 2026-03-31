/**
 * connector.js — Static credential provider
 *
 * This file is volume-mounted into the container so you can swap it out
 * without rebuilding the image.
 */

async function getCredentials() {
  return {
    host: "postgres",
    port: 5432,
    database: "workshop",
    user: "agent_user",
    password: "SuperSecret123!",
    source: "static-config",
    path: "hardcoded",
  };
}

module.exports = { getCredentials };
