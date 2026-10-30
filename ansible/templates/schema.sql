-- Initial schema extracted from the workshop; no destructive reseed.
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

