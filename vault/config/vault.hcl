ui = true
disable_mlock = true

api_addr     = "http://127.0.0.1:18200"
cluster_addr = "http://vault-lab:8201"

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = 1
}

storage "raft" {
  path    = "/vault/data"
  node_id = "vault-lab-1"
}

log_level = "info"