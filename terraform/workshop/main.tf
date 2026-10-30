variable "level" {
  type = number
  validation {
    condition     = var.level >= 3 && var.level <= 10 && floor(var.level) == var.level
    error_message = "level must be a workshop stage from 3 through 10."
  }
}
locals {
  lab_manifest = jsondecode(file("${path.module}/../../labs/manifest.yml"))
  lab          = one([for entry in local.lab_manifest.labs : entry if tonumber(entry.id) == var.level])
  features     = toset(local.lab.features)
  mounts       = merge({ secret = "kv" }, contains(local.features, "database") ? { database = "database" } : {})
  auth         = merge(contains(local.features, "approle") ? { approle = "approle" } : {}, contains(local.features, "jwt") ? { jwt = "jwt" } : {})
  policies = merge({ "zt-static" = file("${path.module}/policies/static.hcl") },
    contains(local.features, "approle") ? { "app-policy" = templatefile("${path.module}/policies/app.hcl", { dynamic = contains(local.features, "database") }) } : {},
  contains(local.features, "jwt") ? { "zero-trust-jwt-lab" = templatefile("${path.module}/policies/jwt.hcl", { roles = contains(local.features, "roles"), ciba = contains(local.features, "ciba") }) } : {})
}
resource "vault_mount" "lab" {
  for_each = local.mounts
  path     = each.key
  type     = each.value
  options  = each.value == "kv" ? { version = "2" } : {}
  lifecycle { prevent_destroy = true }
}
resource "vault_auth_backend" "lab" {
  for_each = local.auth
  path     = each.key
  type     = each.value
  lifecycle { prevent_destroy = true }
}
resource "vault_policy" "lab" {
  for_each = local.policies
  name     = each.key
  policy   = each.value
}
output "contract" {
  value = { schema_version = 1, level = var.level, mounts = keys(local.mounts), auth = keys(local.auth), policies = keys(local.policies) }
}
