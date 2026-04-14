disable_mlock = true

controller {
  name                = "local-controller"
  description         = "Local Boundary controller for the Zero Trust lab"
  public_cluster_addr = "boundary-controller:9201"

  database {
    url = "env://BOUNDARY_POSTGRES_URL"
  }
}

listener "tcp" {
  address     = "0.0.0.0:9200"
  purpose     = "api"
  tls_disable = true
}

listener "tcp" {
  address     = "0.0.0.0:9201"
  purpose     = "cluster"
  tls_disable = true
}

kms "aead" {
  purpose   = "root"
  aead_type = "aes-gcm"
  key       = "8wE8j9QPDOj5bH1Wm4yIXfjWsVT6hMMdOBf4rmkZ4Nk="
  key_id    = "global_root"
}

kms "aead" {
  purpose   = "worker-auth"
  aead_type = "aes-gcm"
  key       = "zPRbHtnJDLZY4udJDrY19LOygjWrmJIdCg3JmhyNOCY="
  key_id    = "global_worker_auth"
}

kms "aead" {
  purpose   = "recovery"
  aead_type = "aes-gcm"
  key       = "CgnM7F2sc9wNn/1wZvSpPSHsD8EzROxDwnt5luxfFWA="
  key_id    = "global_recovery"
}

kms "aead" {
  purpose   = "bsr"
  aead_type = "aes-gcm"
  key       = "YfLw7T+3mW7mV6i0D9m6gA9QKqv1w6L8rXKq3v3P0sU="
  key_id    = "global_bsr"
}