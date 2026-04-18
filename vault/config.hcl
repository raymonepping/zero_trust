ui = true
disable_mlock = true

api_addr = "http://vault:8200"
cluster_addr = "http://vault:8201"

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

storage "raft" {
  path = "/vault/file"
}

# Plugin directory for custom plugins
plugin_directory = "/vault/plugins"

# Optional, but nice for demos
log_level = "info"