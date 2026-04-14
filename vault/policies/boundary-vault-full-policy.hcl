path "database/creds/*" {
  capabilities = ["read"]
}

path "sys/leases/revoke" {
  capabilities = ["update"]
}

path "ssh-client-signer/sign/boundary-role" {
  capabilities = ["update"]
}