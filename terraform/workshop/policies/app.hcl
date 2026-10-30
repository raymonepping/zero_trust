path "secret/data/postgres" { capabilities = ["read"] }
%{ if dynamic ~}
path "database/creds/app-role" { capabilities = ["read"] }
%{ endif ~}
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self" { capabilities = ["update"] }
path "sys/leases/lookup" { capabilities = ["update"] }
path "sys/leases/revoke" { capabilities = ["update"] }
