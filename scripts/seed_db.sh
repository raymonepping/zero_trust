#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration – override via env vars if needed
# ---------------------------------------------------------------------------
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-appdb}"
DB_USER="${DB_USER:-appuser}"
DB_PASS="${DB_PASS:-apppassword}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/../data"

export PGPASSWORD="${DB_PASS}"
PSQL="psql -h ${DB_HOST} -p ${DB_PORT} -U ${DB_USER} -d ${DB_NAME}"

# ---------------------------------------------------------------------------
# Check dependencies
# ---------------------------------------------------------------------------
for cmd in psql jq; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "ERROR: '${cmd}' is required but not installed." >&2
    exit 1
  fi
done

echo "==> Connecting to ${DB_HOST}:${DB_PORT}/${DB_NAME} as ${DB_USER}"

# ---------------------------------------------------------------------------
# Create schema
# ---------------------------------------------------------------------------
echo "==> Creating schema..."
$PSQL <<'SQL'
CREATE TABLE IF NOT EXISTS users (
  id          SERIAL PRIMARY KEY,
  first_name  TEXT NOT NULL,
  last_name   TEXT NOT NULL,
  email       TEXT UNIQUE NOT NULL,
  phone       TEXT,
  city        TEXT,
  country     TEXT,
  joined      DATE
);

CREATE TABLE IF NOT EXISTS orders (
  id              SERIAL PRIMARY KEY,
  user_id         INT NOT NULL REFERENCES users(id),
  item            TEXT NOT NULL,
  category        TEXT,
  quantity        INT NOT NULL DEFAULT 1,
  price           NUMERIC(10,2),
  ordered_at      DATE,
  status          TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'shipped', 'delivered', 'cancelled')),
  classification  TEXT NOT NULL DEFAULT 'internal'
    CHECK (classification IN ('public', 'internal', 'confidential', 'restricted'))
);

CREATE TABLE IF NOT EXISTS preferences (
  id              SERIAL PRIMARY KEY,
  user_id         INT NOT NULL REFERENCES users(id),
  category        TEXT NOT NULL,
  value           TEXT NOT NULL,
  classification  TEXT NOT NULL DEFAULT 'internal'
    CHECK (classification IN ('public', 'internal', 'confidential', 'restricted'))
);

CREATE TABLE IF NOT EXISTS training (
  id              SERIAL PRIMARY KEY,
  user_id         INT NOT NULL REFERENCES users(id),
  course          TEXT NOT NULL,
  provider        TEXT,
  completed_at    DATE,
  score           INT,
  certified       BOOLEAN NOT NULL DEFAULT false,
  classification  TEXT NOT NULL DEFAULT 'internal'
    CHECK (classification IN ('public', 'internal', 'confidential', 'restricted'))
);

CREATE TABLE IF NOT EXISTS tickets (
  id              SERIAL PRIMARY KEY,
  user_id         INT NOT NULL REFERENCES users(id),
  title           TEXT NOT NULL,
  system          TEXT,
  priority        TEXT,
  status          TEXT,
  opened_at       DATE,
  classification  TEXT NOT NULL DEFAULT 'internal'
    CHECK (classification IN ('public', 'internal', 'confidential', 'restricted'))
);

CREATE TABLE IF NOT EXISTS projects (
  id              SERIAL PRIMARY KEY,
  user_id         INT NOT NULL REFERENCES users(id),
  project_name    TEXT NOT NULL,
  role            TEXT,
  budget          NUMERIC(12,2),
  start_date      DATE,
  status          TEXT,
  classification  TEXT NOT NULL DEFAULT 'internal'
    CHECK (classification IN ('public', 'internal', 'confidential', 'restricted'))
);

-- Add columns to existing tables if upgrading from older schema
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name='orders' AND column_name='classification'
  ) THEN
    ALTER TABLE orders ADD COLUMN classification TEXT NOT NULL DEFAULT 'internal'
      CHECK (classification IN ('public', 'internal', 'confidential', 'restricted'));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name='orders' AND column_name='status'
  ) THEN
    ALTER TABLE orders ADD COLUMN status TEXT NOT NULL DEFAULT 'pending'
      CHECK (status IN ('pending', 'processing', 'shipped', 'delivered', 'cancelled'));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name='preferences' AND column_name='classification'
  ) THEN
    ALTER TABLE preferences ADD COLUMN classification TEXT NOT NULL DEFAULT 'internal'
      CHECK (classification IN ('public', 'internal', 'confidential', 'restricted'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_orders_user_id
  ON orders (user_id);
CREATE INDEX IF NOT EXISTS idx_orders_classification
  ON orders (classification);
CREATE INDEX IF NOT EXISTS idx_orders_ordered_at
  ON orders (ordered_at DESC);

CREATE INDEX IF NOT EXISTS idx_preferences_user_id
  ON preferences (user_id);
CREATE INDEX IF NOT EXISTS idx_preferences_classification
  ON preferences (classification);
CREATE INDEX IF NOT EXISTS idx_preferences_user_category
  ON preferences (user_id, category);

CREATE INDEX IF NOT EXISTS idx_training_user_id
  ON training (user_id);
CREATE INDEX IF NOT EXISTS idx_training_classification
  ON training (classification);
CREATE INDEX IF NOT EXISTS idx_training_completed_at
  ON training (completed_at DESC);

CREATE INDEX IF NOT EXISTS idx_tickets_user_id
  ON tickets (user_id);
CREATE INDEX IF NOT EXISTS idx_tickets_classification
  ON tickets (classification);
CREATE INDEX IF NOT EXISTS idx_tickets_opened_at
  ON tickets (opened_at DESC);
CREATE INDEX IF NOT EXISTS idx_tickets_priority_status
  ON tickets (priority, status);

CREATE INDEX IF NOT EXISTS idx_projects_user_id
  ON projects (user_id);
CREATE INDEX IF NOT EXISTS idx_projects_classification
  ON projects (classification);
CREATE INDEX IF NOT EXISTS idx_projects_start_date
  ON projects (start_date DESC);
CREATE INDEX IF NOT EXISTS idx_projects_budget
  ON projects (budget DESC);

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS orders_viewer_policy ON orders;
CREATE POLICY orders_viewer_policy
  ON orders
  FOR SELECT
  TO "viewer-read"
  USING (classification = 'public');

DROP POLICY IF EXISTS orders_support_policy ON orders;
CREATE POLICY orders_support_policy
  ON orders
  FOR SELECT
  TO "support-read"
  USING (classification IN ('public', 'internal'));

DROP POLICY IF EXISTS orders_admin_policy ON orders;
CREATE POLICY orders_admin_policy
  ON orders
  FOR SELECT
  TO "admin-read"
  USING (true);

DROP POLICY IF EXISTS orders_support_write_policy ON orders;
CREATE POLICY orders_support_write_policy
  ON orders
  FOR ALL
  TO "support-write"
  USING (classification IN ('public', 'internal'))
  WITH CHECK (classification IN ('public', 'internal'));
SQL

# ---------------------------------------------------------------------------
# Truncate existing data (safe for workshop — preserves schema)
# ---------------------------------------------------------------------------
echo "==> Truncating existing data..."
$PSQL -c "TRUNCATE TABLE projects, tickets, training, preferences, orders, users RESTART IDENTITY CASCADE;" >/dev/null
echo "    done."

# ---------------------------------------------------------------------------
# Seed users
# ---------------------------------------------------------------------------
echo "==> Seeding users from data/users.json..."
jq -c '.[]' "${DATA_DIR}/users.json" | while IFS= read -r row; do
  id=$(echo "$row" | jq -r '.id')
  first_name=$(echo "$row" | jq -r '.first_name')
  last_name=$(echo "$row" | jq -r '.last_name')
  email=$(echo "$row" | jq -r '.email')
  phone=$(echo "$row" | jq -r '.phone')
  city=$(echo "$row" | jq -r '.city')
  country=$(echo "$row" | jq -r '.country')
  joined=$(echo "$row" | jq -r '.joined')

  $PSQL -c "
    INSERT INTO users (id, first_name, last_name, email, phone, city, country, joined)
    VALUES (${id}, '${first_name}', '${last_name}', '${email}', '${phone}', '${city}', '${country}', '${joined}')
    ON CONFLICT (email) DO UPDATE SET
      first_name = EXCLUDED.first_name,
      last_name  = EXCLUDED.last_name,
      phone      = EXCLUDED.phone,
      city       = EXCLUDED.city,
      country    = EXCLUDED.country,
      joined     = EXCLUDED.joined;
  " >/dev/null
  echo "    user: ${first_name} ${last_name}"
done

# ---------------------------------------------------------------------------
# Seed orders
# ---------------------------------------------------------------------------
echo "==> Seeding orders from data/activity.json..."
jq -c '.orders[]' "${DATA_DIR}/activity.json" | while IFS= read -r row; do
  user_id=$(echo "$row" | jq -r '.user_id')
  item=$(echo "$row" | jq -r '.item' | sed "s/'/''/g")
  category=$(echo "$row" | jq -r '.category')
  quantity=$(echo "$row" | jq -r '.quantity')
  price=$(echo "$row" | jq -r '.price')
  ordered_at=$(echo "$row" | jq -r '.ordered_at')
  status=$(echo "$row" | jq -r '.status // "pending"')
  classification=$(echo "$row" | jq -r '.classification // "internal"')

  $PSQL -c "
    INSERT INTO orders (user_id, item, category, quantity, price, ordered_at, status, classification)
    VALUES (${user_id}, '${item}', '${category}', ${quantity}, ${price}, '${ordered_at}', '${status}', '${classification}');
  " >/dev/null
  echo "    order: [user ${user_id}] [${classification}] [${status}] ${item}"
done

# ---------------------------------------------------------------------------
# Seed preferences
# ---------------------------------------------------------------------------
echo "==> Seeding preferences from data/activity.json..."
jq -c '.preferences[]' "${DATA_DIR}/activity.json" | while IFS= read -r row; do
  user_id=$(echo "$row" | jq -r '.user_id')
  category=$(echo "$row" | jq -r '.category')
  value=$(echo "$row" | jq -r '.value' | sed "s/'/''/g")
  classification=$(echo "$row" | jq -r '.classification // "internal"')

  $PSQL -c "
    INSERT INTO preferences (user_id, category, value, classification)
    VALUES (${user_id}, '${category}', '${value}', '${classification}')
    ON CONFLICT DO NOTHING;
  " >/dev/null
  echo "    preference: [user ${user_id}] [${classification}] ${category}"
done

# ---------------------------------------------------------------------------
# Seed training
# ---------------------------------------------------------------------------
echo "==> Seeding training from data/training.json..."
jq -c '.[]' "${DATA_DIR}/training.json" | while IFS= read -r row; do
  user_id=$(echo "$row" | jq -r '.user_id')
  course=$(echo "$row" | jq -r '.course' | sed "s/'/''/g")
  provider=$(echo "$row" | jq -r '.provider' | sed "s/'/''/g")
  completed_at=$(echo "$row" | jq -r '.completed_at')
  score=$(echo "$row" | jq -r '.score')
  certified=$(echo "$row" | jq -r '.certified')
  classification=$(echo "$row" | jq -r '.classification // "internal"')

  $PSQL -c "
    INSERT INTO training (user_id, course, provider, completed_at, score, certified, classification)
    VALUES (${user_id}, '${course}', '${provider}', '${completed_at}', ${score}, ${certified}, '${classification}');
  " >/dev/null
  echo "    training: [user ${user_id}] [${classification}] ${course}"
done

# ---------------------------------------------------------------------------
# Seed tickets
# ---------------------------------------------------------------------------
echo "==> Seeding tickets from data/tickets.json..."
jq -c '.[]' "${DATA_DIR}/tickets.json" | while IFS= read -r row; do
  user_id=$(echo "$row" | jq -r '.user_id')
  title=$(echo "$row" | jq -r '.title' | sed "s/'/''/g")
  system=$(echo "$row" | jq -r '.system' | sed "s/'/''/g")
  priority=$(echo "$row" | jq -r '.priority')
  status=$(echo "$row" | jq -r '.status')
  opened_at=$(echo "$row" | jq -r '.opened_at')
  classification=$(echo "$row" | jq -r '.classification // "internal"')

  $PSQL -c "
    INSERT INTO tickets (user_id, title, system, priority, status, opened_at, classification)
    VALUES (${user_id}, '${title}', '${system}', '${priority}', '${status}', '${opened_at}', '${classification}');
  " >/dev/null
  echo "    ticket: [user ${user_id}] [${classification}] ${title}"
done

# ---------------------------------------------------------------------------
# Seed projects
# ---------------------------------------------------------------------------
echo "==> Seeding projects from data/projects.json..."
jq -c '.[]' "${DATA_DIR}/projects.json" | while IFS= read -r row; do
  user_id=$(echo "$row" | jq -r '.user_id')
  project_name=$(echo "$row" | jq -r '.project_name' | sed "s/'/''/g")
  role=$(echo "$row" | jq -r '.role' | sed "s/'/''/g")
  budget=$(echo "$row" | jq -r '.budget')
  start_date=$(echo "$row" | jq -r '.start_date')
  status=$(echo "$row" | jq -r '.status')
  classification=$(echo "$row" | jq -r '.classification // "internal"')

  $PSQL -c "
    INSERT INTO projects (user_id, project_name, role, budget, start_date, status, classification)
    VALUES (${user_id}, '${project_name}', '${role}', ${budget}, '${start_date}', '${status}', '${classification}');
  " >/dev/null
  echo "    project: [user ${user_id}] [${classification}] ${project_name}"
done

echo ""
echo "==> Done. Seeded users, orders, preferences, training, tickets, and projects."
