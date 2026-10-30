# Backend identity: caller-role selection is enforced by the application.
%{ if roles ~}
path "database/creds/viewer-read" { capabilities = ["read"] }
path "database/creds/support-read" { capabilities = ["read"] }
path "database/creds/admin-read" { capabilities = ["read"] }
%{ else ~}
path "database/creds/app-role" { capabilities = ["read"] }
%{ endif ~}
%{ if ciba ~}
# CIBA approval is an application gate, not cryptographically enforced by Vault.
path "database/creds/support-write" { capabilities = ["read"] }
%{ endif ~}
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self" { capabilities = ["update"] }
path "sys/leases/lookup" { capabilities = ["update"] }
path "sys/leases/revoke" { capabilities = ["update"] }
