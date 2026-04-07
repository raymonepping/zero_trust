// roleResolver.js — maps a full Keycloak JWT payload to a Vault DB role

"use strict";

const ROLE_MAP = {
  viewer:  "viewer-read",
  support: "support-read",
  admin:   "admin-read",
};

const CANONICAL = new Set(["viewer-read", "support-read", "admin-read"]);

function resolveVaultRole(user) {
  if (!user) return "viewer-read";

  const realmRoles = user.realm_access?.roles || [];
  const groups     = user.groups || [];

  // Pass-through if a canonical vault role name is already a realm role
  for (const role of realmRoles) {
    if (CANONICAL.has(role)) return role;
  }

  // Map Keycloak realm roles → Vault DB role (highest privilege wins)
  if (realmRoles.includes("admin")   || groups.includes("/admin"))   return ROLE_MAP.admin;
  if (realmRoles.includes("support") || groups.includes("/support")) return ROLE_MAP.support;
  if (realmRoles.includes("viewer")  || groups.includes("/viewer"))  return ROLE_MAP.viewer;

  // Fallback: least privilege
  return "viewer-read";
}

module.exports = { resolveVaultRole };
