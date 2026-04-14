disable_mlock = true

listener "tcp" {
  address = "0.0.0.0:9202"
  purpose = "proxy"
}

worker {
  initial_upstreams = ["boundary-ingress-worker:9202"]
  name              = "local-egress-worker"
  public_addr       = "boundary-egress-worker:9202"

  tags {
    type = ["egress", "private"]
  }
}

kms "aead" {
  purpose   = "worker-auth"
  aead_type = "aes-gcm"
  key       = "zPRbHtnJDLZY4udJDrY19LOygjWrmJIdCg3JmhyNOCY="
  key_id    = "global_worker_auth"
}

kms "aead" {
  purpose   = "worker-auth-storage"
  aead_type = "aes-gcm"
  key       = "NwgDy1zlcQuNrRIBBqFYh4COuC2kg3omF5olgnJMyek="
  key_id    = "worker_auth_storage"
}