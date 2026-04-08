From Hardcoded Credentials to Context-Aware Trust
=================================================

Building a Zero Trust workshop that starts wired, then evolves through Vault, AppRole, JWT, dynamic database credentials, and row-level security.

There is a big difference between showing Vault in a demo and teaching people why it matters.

Many demos stop at "read a password from Vault KV." That is useful, but it does not fundamentally change how trust works. If the application still uses a shared database account, if every user gets the same backend behavior, and if identity is still mostly implicit, then secrets storage has improved while the trust model has not.

That is why I built this workshop.

The goal is not to show a single happy-path Vault integration. The goal is to let students move through the same progression many teams face in the real world:

- hardcoded credentials
- `.env`-driven credentials
- Vault KV
- AppRole for workload identity
- dynamic PostgreSQL credentials
- Keycloak JWTs for end-user identity
- role-based database access
- PostgreSQL Row Level Security
- audit logging and rotation

The source for the workshop lives here:

https://github.com/raymonepping/zero_trust

By the end, students stop thinking of Vault as "just a secrets manager" and start seeing it as part of a broader trust system.

The Workshop Architecture
-------------------------

The environment is intentionally built as a small, realistic platform:

- PostgreSQL
- Vault Enterprise
- Ollama
- Express backend
- React frontend
- OpenLDAP
- Keycloak

The high-level flow is simple:

1. The frontend sends a question or request to the backend.
2. The backend retrieves data from PostgreSQL.
3. The backend enriches that data with identity and context.
4. Ollama turns the result into a human-readable answer.

What changes throughout the workshop is not the shape of the application. What changes is the trust model behind it.

At the beginning, the backend runs with hardcoded database credentials. Later, it authenticates to Vault, requests short-lived credentials, and eventually selects the right database role based on the authenticated Keycloak user.

That progression is the real lesson.

The Repository and Startup Goal
-------------------------------

One of the workshop design goals is that students should be able to get to a working baseline quickly.

The intended starting path is:

1. Clone the repository locally.
2. Start the stack with Docker Compose.
3. Seed PostgreSQL using the provided script.
4. Seed LDAP from the provided LDIF using the provided script.
5. Configure Keycloak with the provided script.
6. Open the frontend and start from the wired connector.
7. Move into Vault manually and progressively enable the trust model.

That matters because it keeps the initial friction low. Students do not need to understand the final architecture before they can see the first working state.

```bash
git clone https://github.com/raymonepping/zero_trust.git
cd zero_trust

docker compose up -d
./scripts/seed_db.sh
LDAP_HOST=localhost LDAP_PORT=1389 ./scripts/setup_ldap.sh
./scripts/setup_keycloak.sh -u http://localhost:8082
```

Then open:

- Frontend: `http://localhost:5173`
- Vault: `http://localhost:8200`
- phpLDAPadmin: `http://localhost:8081`
- Keycloak: `http://localhost:8082`

The frontend starts intentionally in the wired mode. That is the point. Students first see the insecure baseline working before they improve it.

Docker Compose Design
---------------------

The Compose file is intentionally opinionated. Some design choices are there to make architectural boundaries visible:

- the frontend and backend are separated onto different internal networks
- PostgreSQL, Vault, LDAP, Keycloak, and Ollama are not directly reachable from the browser
- backend and frontend are bind-mounted so students can edit live without rebuilding everything
- health checks make the startup order more predictable
- Ollama is isolated on an egress-capable network so model pulls are possible without making every service broadly reachable

This creates an immediate architectural lesson: applications should not talk directly to everything.

The backend becomes the policy enforcement point between the user-facing system and the sensitive services behind it.

The current Compose setup also includes pinned workshop images for the frontend and backend.

Folder Structure and Why It Matters
-----------------------------------

The repository is organized to make the trust evolution visible:

- `backend/` contains the Express API, auth middleware, connector logic, and role mapping
- `frontend/` contains the React UI
- `data/` contains the workshop data and connector variants
- `scripts/` contains all bootstrap, transition, validation, and operational helper scripts
- `vault/` contains Vault configuration and audit paths
- `ldap/` contains the bootstrap LDIF
- `db/` contains PostgreSQL build and schema setup
- `ollama/` contains the local LLM container build and startup behavior

One of the most important mechanics is the connector swap.

The workshop keeps `backend/connector.js` bind-mounted so students can change trust models without rebuilding images. The default checked-in connector is the wired one, which returns:

- host `db`
- database `appdb`
- user `appuser`
- password `apppassword`

That insecure starting point is deliberate.

The Minimum `.env` Students Need
--------------------------------

For the initial startup, database seeding, LDAP setup, and wired frontend flow, students only need a small `.env`:

```env
NODE_ENV=development
LOG_LEVEL=info
PORT=3000

DATABASE_URL=postgres://appuser:apppassword@db:5432/appdb
POSTGRES_DB_HOST=db
POSTGRES_DB_PORT=5432
POSTGRES_DB=appdb
POSTGRES_USER=appuser
POSTGRES_PASSWORD=apppassword

OLLAMA_ADDR=http://ollama:11434
```

Later phases need additional values after Keycloak and Vault are configured:

```env
VAULT_ADDR=http://vault:8200
VAULT_TOKEN=<your-vault-token>
VAULT_MODE=dynamic
VAULT_DB_ROLE=app-role
VAULT_DB_ROLE_VIEWER=viewer-read
VAULT_DB_ROLE_SUPPORT=support-read
VAULT_DB_ROLE_ADMIN=admin-read
VAULT_KV_PATH=secret/data/postgres

JWKS_URL=http://keycloak:8080/realms/zero-trust/protocol/openid-connect/certs
JWT_ISSUER=http://keycloak:8080/realms/zero-trust
KEYCLOAK_ADDR=http://keycloak:8080
KEYCLOAK_REALM=zero-trust
KEYCLOAK_CLIENT_ID=backend
KEYCLOAK_CLIENT_SECRET=<client-secret-from-setup-keycloak>
KEYCLOAK_USERNAME=repping
KEYCLOAK_PASSWORD=password
```

Two practical notes:

- inside containers, services talk to `vault`, `db`, `keycloak`, and `ollama` by service name, not `localhost`
- students do not need Vault or Keycloak secrets on day one, but they do need them once they move beyond the wired and `.env` phases

Vault Phases and Connector Progression
--------------------------------------

Connector progression:

- `wired` -> hardcoded credentials in code
- `env` -> credentials loaded from `.env`
- `vault` -> static credentials from Vault KV
- `dynamic` -> Vault database engine issues short-lived PostgreSQL credentials
- `approle` -> backend authenticates to Vault with AppRole, then reads KV
- `approle-dynamic` -> AppRole plus dynamic database credentials
- `approle-rotation` -> AppRole plus proactive lease rotation
- `jwt-rotation` -> Keycloak JWT drives Vault-issued dynamic credentials
- `jwt-roles` -> JWT claims choose role-scoped dynamic credentials

The `setup_vault.sh` script mirrors that evolution:

- Phase 01: KV v2 plus a static PostgreSQL secret
- Phase 02: database secrets engine, PostgreSQL group roles, and DB roles
- Phase 03: AppRole auth and app policy
- Phase 04: JWT auth and JWT role
- Phase 05: LDAP auth and mapping
- Phase 06: audit logging

PostgreSQL Role Mapping
-----------------------

One important distinction in the workshop is the difference between Vault role names and PostgreSQL group role names.

Vault role names:

- `viewer-read`
- `support-read`
- `admin-read`

PostgreSQL group roles:

- `viewer-read`
- `support-read`
- `admin-read`

Vault issues a temporary PostgreSQL user and grants membership in one of the PostgreSQL group roles.

For example:

```sql
CREATE ROLE "viewer-read" NOLOGIN;
GRANT SELECT ON users TO "viewer-read";

CREATE ROLE "v-jwt-repp-viewer-abc123" WITH LOGIN PASSWORD 'generated';
GRANT "viewer-read" TO "v-jwt-repp-viewer-abc123";
```

That distinction matters because Vault orchestrates access, but PostgreSQL still controls the underlying table grants.

JWT Role Resolution
-------------------

The backend uses `roleResolver.js` to translate Keycloak roles into Vault database roles:

- `viewer` -> `viewer-read`
- `support` -> `support-read`
- `admin` -> `admin-read`

The resolver first checks whether the JWT already contains canonical Vault role names. If not, it falls back to mapping Keycloak realm roles or groups.

That means a JWT containing:

```json
{
  "realm_access": {
    "roles": ["support"]
  }
}
```

results in Vault requesting the `support-read` database role.

PostgreSQL Row Level Security
-----------------------------

PostgreSQL grants alone only control which tables can be accessed. They do not control which rows inside a table are visible.

That is where Row Level Security becomes essential.

```sql
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY orders_viewer_policy
ON orders
FOR SELECT
TO "viewer-read"
USING (classification = 'public');

CREATE POLICY orders_support_policy
ON orders
FOR SELECT
TO "support-read"
USING (classification IN ('public', 'internal'));

CREATE POLICY orders_admin_policy
ON orders
FOR SELECT
TO "admin-read"
USING (true);
```

This is one of the strongest Zero Trust lessons in the workshop. The application should not be the only place where access rules live. The database itself should enforce boundaries too.

Architecture Flow
-----------------

By the final workshop phase, the end-to-end flow looks like this:

1. User logs in through Keycloak.
2. Backend validates the JWT.
3. Backend maps the user role through `roleResolver.js`.
4. Backend authenticates to Vault.
5. Vault issues short-lived PostgreSQL credentials.
6. PostgreSQL enforces grants and Row Level Security.
7. Ollama generates a contextual response.
8. Vault audit logs record the activity.

That is very different from:

```txt
user: appuser
password: apppassword
```

Why the Workshop Works
----------------------

This workshop works because students can feel the progression instead of being told about it abstractly.

They experience:

- why hardcoded credentials are attractive and dangerous
- why `.env` is only a partial improvement
- why Vault KV is useful but still static
- why dynamic credentials change the trust model
- why workloads need workload identity
- why human identity should influence backend access
- why database roles and RLS matter
- why audit and rotation are part of the trust story

By the end, the environment has evolved into something much more mature:

- dynamic Vault-issued credentials
- AppRole-based backend authentication
- JWT-based end-user identity
- role-scoped database access
- PostgreSQL Row Level Security
- audit logging
- rotation and revocation paths

That is the difference between protecting a secret and building trust.

Final Thought
-------------

Most organizations do not jump directly from hardcoded passwords to a fully dynamic Zero Trust architecture. They evolve.

That is why a workshop like this matters.

It starts with patterns people already recognize. Then it introduces better ways of thinking:

- machine identity
- human identity
- least privilege
- short-lived credentials
- contextual access
- database-side enforcement
- auditability

Vault becomes more than a secret store.
JWT becomes more than a login token.
PostgreSQL becomes more than a database.

Together, they become a trust system.
That is where Zero Trust starts to feel real.
