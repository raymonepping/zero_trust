terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "= 5.9.0"
    }
  }
  backend "local" {}
}
provider "vault" {
  # VAULT_ADDR / VAULT_TOKEN are injected by the private runner. The provider
  # obtains its ordinary bounded child token; credentials are never inputs.
  max_lease_ttl_seconds = 1200
}
