vault {
  address = "http://vault:8200"

  retry {
    num_retries = 5
  }
}

# ---------------------------------------------------------------------------
# Auto-auth via AppRole
# Populate role_id and secret_id by running:
#   ./scripts/setup_vault.sh   (step 03 — AppRole)
# then copy the values into:
#   vault-agent/config/role_id
#   vault-agent/config/secret_id
# ---------------------------------------------------------------------------
auto_auth {
  method "approle" {
    mount_path = "auth/approle"

    config = {
      role_id_file_path                   = "/vault/config/role_id"
      secret_id_file_path                 = "/vault/config/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/vault/secrets/.vault-token"
    }
  }
}

# ---------------------------------------------------------------------------
# Render dynamic DB credentials to a JSON file consumed by the backend.
# Vault Agent renews the lease automatically before it expires.
# ---------------------------------------------------------------------------
template {
  contents = <<EOT
{{ with secret "database/creds/app-role" -}}
{
  "username":       "{{ .Data.username }}",
  "password":       "{{ .Data.password }}",
  "host":           "db",
  "port":           5432,
  "database":       "appdb",
  "lease_id":       "{{ .LeaseID }}",
  "lease_duration": {{ .LeaseDuration }}
}
{{- end }}
EOT
  destination = "/vault/secrets/db-creds.json"
}
