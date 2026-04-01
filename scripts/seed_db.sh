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

-- Add classification column to existing tables if upgrading from older schema
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
    WHERE table_name='preferences' AND column_name='classification'
  ) THEN
    ALTER TABLE preferences ADD COLUMN classification TEXT NOT NULL DEFAULT 'internal'
      CHECK (classification IN ('public', 'internal', 'confidential', 'restricted'));
  END IF;
END $$;
SQL

# ---------------------------------------------------------------------------
# Truncate existing data (safe for workshop — preserves schema)
# ---------------------------------------------------------------------------
echo "==> Truncating existing data..."
$PSQL -c "TRUNCATE TABLE preferences, orders, users RESTART IDENTITY CASCADE;" >/dev/null
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
  classification=$(echo "$row" | jq -r '.classification // "internal"')

  $PSQL -c "
    INSERT INTO orders (user_id, item, category, quantity, price, ordered_at, classification)
    VALUES (${user_id}, '${item}', '${category}', ${quantity}, ${price}, '${ordered_at}', '${classification}');
  " >/dev/null
  echo "    order: [user ${user_id}] [${classification}] ${item}"
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

echo ""
echo "==> Done. Seeded users, orders, and preferences."
