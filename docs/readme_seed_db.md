# seed_db.sh — Database Seeding Script

**Location:** `scripts/seed_db.sh`

This script creates and populates the workshop database from scratch. You run it once after the stack is up, and again any time you want to reset the data to a clean state.

---

## What it does, step by step

### 1. Configuration

```bash
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-appdb}"
DB_USER="${DB_USER:-appuser}"
DB_PASS="${DB_PASS:-apppassword}"
```

The script sets sensible defaults for the database connection. Every value can be overridden by setting an environment variable before running the script:

```bash
DB_HOST=myserver ./scripts/seed_db.sh
```

The `:-` syntax means *"use this value if the variable is not set or is empty"* — a common Bash pattern you will see throughout this workshop.

### 2. Dependency check

```bash
for cmd in psql jq; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "ERROR: '${cmd}' is required but not installed."
    exit 1
  fi
done
```

Before doing any real work, the script checks that two tools are available:

| Tool | Purpose |
|------|---------|
| `psql` | PostgreSQL client — sends SQL to the database |
| `jq` | JSON processor — reads and parses the seed data files |

If either is missing the script exits immediately with a clear error rather than failing partway through.

### 3. Schema creation

The script creates **six tables** using `CREATE TABLE IF NOT EXISTS`, which means it is safe to run multiple times — it will not fail if the tables already exist.

#### `users`
The anchor table. Every other table links back here via a `user_id` foreign key.

| Column | Type | Notes |
|--------|------|-------|
| `id` | SERIAL PK | Auto-incrementing integer |
| `first_name` / `last_name` | TEXT | |
| `email` | TEXT UNIQUE | Enforces one row per email address |
| `phone` / `city` / `country` | TEXT | |
| `joined` | DATE | When the user joined |

#### `orders`
Purchase records linked to users.

| Column | Type | Notes |
|--------|------|-------|
| `status` | TEXT | `pending`, `processing`, `shipped`, `delivered`, `cancelled` |
| `classification` | TEXT | `public`, `internal`, `confidential`, `restricted` |

The `status` and `classification` columns use `CHECK` constraints — PostgreSQL will reject any value not in the allowed list.

#### `preferences`
User settings and preferences (e.g. notification preferences, theme choices).

#### `training`
Training and certification records per user — includes `score`, `certified` (boolean), and `completed_at` date.

#### `tickets`
Support or IT tickets linked to users — includes `priority`, `status`, and which `system` the ticket concerns.

#### `projects`
Projects a user is involved in — includes `role`, `budget`, `start_date`, and `status`.

---

### 4. Idempotent schema upgrades

```sql
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name='orders' AND column_name='classification'
  ) THEN
    ALTER TABLE orders ADD COLUMN classification ...
  END IF;
END $$;
```

This block handles upgrading an **existing** database that was created by an older version of the schema. It checks whether columns exist before adding them, so the script is safe to run against both a fresh database and an older one. You do not need to drop and recreate the database just to pick up a new column.

---

### 5. Indexes

The script creates indexes to speed up common queries. Each index is created with `CREATE INDEX IF NOT EXISTS` — again, safe to run multiple times.

| Index | Table | Why it exists |
|-------|-------|---------------|
| `idx_orders_user_id` | orders | Fast lookup of all orders for a user |
| `idx_orders_classification` | orders | Filter by data sensitivity level |
| `idx_orders_ordered_at` | orders | Sort/filter by date, newest first |
| `idx_preferences_user_category` | preferences | Composite: user + category lookups |
| `idx_training_completed_at` | training | Sort training records by completion date |
| `idx_tickets_priority_status` | tickets | Composite: find open high-priority tickets |
| `idx_projects_budget` | projects | Sort projects by budget |

---

### 6. Row Level Security (RLS) on `orders`

This is the most important part for the zero trust workshop. RLS lets PostgreSQL enforce data access rules **inside the database itself**, independent of the application.

```sql
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
```

Once RLS is enabled, a database role can only see rows that match its policy — even if it runs `SELECT * FROM orders`. Four policies are created:

| Policy | Role | What it can see |
|--------|------|----------------|
| `orders_viewer_policy` | `viewer-read` | Only `public` rows |
| `orders_support_policy` | `support-read` | `public` and `internal` rows |
| `orders_admin_policy` | `admin-read` | All rows (`USING (true)`) |
| `orders_support_write_policy` | `support-write` | Read and write `public` + `internal` rows |

These roles (`viewer-read`, `support-read`, etc.) are the **Vault dynamic database roles**. When Vault issues a short-lived credential for the `viewer-read` role, that user can connect to Postgres and will automatically only see public orders — no extra application logic needed.

> **Key insight:** The security boundary lives in the database, not just the application. Even if a bug or misconfiguration in the backend leaked a credential, the credential itself is scoped to only what that role is allowed to see.

---

### 7. Truncation

```bash
TRUNCATE TABLE projects, tickets, training, preferences, orders, users RESTART IDENTITY CASCADE;
```

Before inserting fresh data, the script wipes all existing rows. `RESTART IDENTITY` resets the auto-increment counters back to 1, so IDs are predictable. `CASCADE` ensures child rows (orders, preferences, etc.) are deleted before users, avoiding foreign key errors.

---

### 8. Seeding data from JSON files

All seed data lives in the `data/` directory. The script reads each file with `jq`, iterates over every record, and inserts it into the database.

| File | Table | Records |
|------|-------|---------|
| `data/users.json` | `users` | 6 users |
| `data/activity.json` | `orders` | 28 orders |
| `data/activity.json` | `preferences` | 39 preferences |
| `data/training.json` | `training` | 15 records |
| `data/tickets.json` | `tickets` | 12 tickets |
| `data/projects.json` | `projects` | 12 projects |

#### How the JSON-to-SQL loop works

```bash
jq -c '.[]' data/users.json | while IFS= read -r row; do
  first_name=$(echo "$row" | jq -r '.first_name')
  ...
  $PSQL -c "INSERT INTO users (...) VALUES (...);"
done
```

- `jq -c '.[]'` — prints each array element as a single compact JSON line
- `while IFS= read -r row` — reads one line (one record) at a time
- `jq -r '.field'` — extracts a raw string value from the JSON
- `sed "s/'/''/g"` — escapes any single quotes in text fields to prevent SQL errors

The `users` and `preferences` inserts use `ON CONFLICT DO UPDATE` / `ON CONFLICT DO NOTHING` — re-running the script will update existing users rather than throwing a duplicate key error.

#### Classification breakdown

The seed data spans all four classification levels, giving you realistic data to demonstrate RLS policies:

| Classification | Visibility |
|---------------|------------|
| `public` | All roles including `viewer-read` |
| `internal` | `support-read` and above |
| `confidential` | `admin-read` only |
| `restricted` | `admin-read` only |

---

## How to run it

**From the host** (requires `psql` and `jq` installed locally):

```bash
cd /path/to/zero_trust
./scripts/seed_db.sh
```

**Against the running Docker container** (no local `psql` needed):

```bash
docker exec -i zero_trust_db bash -c "
  PGPASSWORD=apppassword psql -U appuser -d appdb
" < <(cat scripts/seed_db.sh)
```

Or, more simply, exec into the container first:

```bash
docker exec -it zero_trust_db bash
# then run psql commands manually
```

**Reset to a clean state at any time:**

```bash
./scripts/seed_db.sh   # truncates and re-seeds everything
```

---

## Prerequisites

| Requirement | Why |
|-------------|-----|
| `psql` installed | The PostgreSQL client sends SQL to the database |
| `jq` installed | Parses the JSON seed files |
| Database running | The `zero_trust_db` container must be up and healthy |
| Network access | `DB_HOST` must be reachable (default: `localhost` on port `5432`) |

Install on macOS:
```bash
brew install postgresql jq
```

Install on Ubuntu/Debian:
```bash
sudo apt-get install postgresql-client jq
```

---

## Troubleshooting

**`ERROR: 'psql' is required but not installed.`**
Install the PostgreSQL client (you do not need the full server, just the client tools).

**`psql: error: connection to server on socket "/tmp/.s.PGSQL.5432" failed`**
The database is not reachable. Make sure the stack is running (`docker compose up db`) and that `DB_HOST` points to the right address. When running against Docker, `DB_HOST=localhost` works if the container's port 5432 is published to the host.

**`ERROR: insert or update on table "orders" violates foreign key constraint`**
The `users` table must be seeded before the other tables. The script does this in the correct order — if you see this error you may have a partially seeded database. Run the full script again; the truncation step will clean it up.

**`ERROR: new row for relation "orders" violates check constraint`**
A value in one of the JSON files does not match the allowed list (e.g. an unrecognised `status` or `classification`). Check the relevant JSON file in `data/`.

**RLS policies not working as expected**
RLS only applies to non-superuser roles. The `appuser` account used to create the schema is a superuser in the workshop stack and bypasses RLS. Dynamic Vault credentials (e.g. `viewer-read`, `support-read`) are regular roles and will be properly restricted.
