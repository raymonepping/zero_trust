# verify_stack

**Audience:** students and engineers

This is the short preflight guide for the workshop stack.

Before you run the setup scripts, use the verifier scripts in this order so you fail early and in the right layer.

---

## Recommended order

### 1. PostgreSQL

Run:

```bash
./scripts/verify_postgresql.sh
```

Why first:

- the workshop data lives here
- the backend depends on it
- Vault dynamic database roles also depend on it later

You want to know early whether:

- the `db_data` volume exists
- `appuser` exists
- the workshop tables exist

If this fails, fix PostgreSQL before touching Vault, LDAP, or Keycloak.

---

### 2. LDAP

Run:

```bash
./scripts/verify_ldap.sh
```

Why second:

- Keycloak federation depends on LDAP
- the login flow depends on LDAP-backed identities

You want to confirm:

- `ldapsearch` and `ldapadd` are installed
- the OpenLDAP container is up
- the admin bind works
- `ou=people` and `ou=groups` are reachable

If this fails, do not run `setup_keycloak.sh` yet.

---

### 3. Keycloak

Run:

```bash
./scripts/verify_keycloak.sh
```

Why third:

- Keycloak depends on LDAP being available
- the frontend login flow and JWT-based connector modes depend on Keycloak

You want to confirm:

- Keycloak is reachable on the host
- the master realm OIDC metadata is live
- `kcadm.sh` exists in the container
- bootstrap admin login works

If this fails, the identity flow is not ready.

---

### 4. Vault

Run:

```bash
./scripts/verify_vault.sh
```

Why fourth:

- Vault is needed for the Vault-based connector modes
- the backend uses it for static, dynamic, AppRole, JWT, and CIBA-related flows

You want to confirm:

- Vault is reachable
- Vault is initialized
- Vault is unsealed
- and, when `VAULT_TOKEN` is available, which secrets engines and auth methods are enabled

If Vault is sealed, stop here and fix that first.

---

## Suggested preflight sequence

From the repository root:

```bash
./scripts/verify_postgresql.sh
./scripts/verify_ldap.sh
./scripts/verify_keycloak.sh
./scripts/verify_vault.sh
```

That sequence validates the core workshop dependencies from the bottom up:

1. data
2. directory
3. identity provider
4. secrets platform

That ordering is intentional. It keeps later failures from hiding earlier root causes.

---

## What to run after the verifiers

Once the verifiers pass, the usual setup order is:

```bash
./scripts/seed_db.sh
./scripts/setup_ldap.sh
./scripts/setup_keycloak.sh
./scripts/unseal_vault.sh
source ./scripts/vault_login.sh
./scripts/setup_vault.sh --phase all
```

If you are following the workshop progressively, you may run only the Vault phases you need rather than `--phase all`.

---

## Failure strategy

If a verifier fails:

- do not continue to the next layer
- fix the failed layer first
- rerun the same verifier
- only then continue

This saves time and prevents misleading follow-on errors.

---

## Related documents

- [docs/readme_verify_postgresql.md](./readme_verify_postgresql.md)
- [docs/readme_verify_ldap.md](./readme_verify_ldap.md)
- [docs/readme_verify_keycloak.md](./readme_verify_keycloak.md)
- [docs/readme_verify_vault.md](./readme_verify_vault.md)
- [docs/readme_seed_db.md](./readme_seed_db.md)
- [docs/readme_setup_ldap.md](./readme_setup_ldap.md)
- [docs/readme_setup_keycloak.md](./readme_setup_keycloak.md)
- [docs/readme_setup_vault.md](./readme_setup_vault.md)
