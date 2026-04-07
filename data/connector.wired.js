/**
 * connector.js — Static credential provider
 *
 * This file is volume-mounted into the container so you can swap it out
 * without rebuilding the image.
 */

async function getCredentials() {
  return {
    host: "db",
    port: 5432,
    database: "appdb",
    user: "appuser",
    password: "apppassword",
    source: "static-config",
    path: "hardcoded",
  };
}

module.exports = { getCredentials };
