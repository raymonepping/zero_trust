#!/usr/bin/python
"""Transactional initial fixtures and live PostgreSQL privilege reconciliation."""

from pathlib import Path
import json
import time
from ansible.module_utils.basic import AnsibleModule

TABLES = ["users", "orders", "preferences", "training", "tickets", "projects"]


def seed_rows(fixtures):
    files = {
        n: json.loads((Path(fixtures) / (n + ".json")).read_text())
        for n in ["users", "activity", "training", "tickets", "projects"]
    }
    return dict(
        users=files["users"],
        orders=files["activity"]["orders"],
        preferences=files["activity"]["preferences"],
        training=files["training"],
        tickets=files["tickets"],
        projects=files["projects"],
    )


def main():
    m = AnsibleModule(
        argument_spec=dict(
            port=dict(type="int", required=True),
            schema=dict(required=True),
            fixtures=dict(required=True),
            features=dict(type="list", elements="str", required=True),
        ),
        supports_check_mode=True,
    )
    try:
        import psycopg
        from psycopg import sql

        for _ in range(50):
            try:
                db = psycopg.connect(
                    host="127.0.0.1",
                    port=m.params["port"],
                    dbname="appdb",
                    user="appuser",
                    password="apppassword",
                    connect_timeout=3,
                )
                break
            except psycopg.OperationalError:
                time.sleep(2)
        else:
            m.fail_json(msg="Database authentication/readiness failed")
        changed = False
        with db:
            with db.cursor() as cur:
                cur.execute("SELECT to_regclass('public.zt_migrations')")
                has_history = cur.fetchone()[0] is not None
                if not has_history and not m.check_mode:
                    cur.execute("CREATE TABLE zt_migrations (name text PRIMARY KEY)")
                    changed = True
                migrated = False
                if has_history:
                    cur.execute(
                        "SELECT EXISTS (SELECT FROM zt_migrations WHERE name='baseline-v1')"
                    )
                    migrated = cur.fetchone()[0]
                if not migrated:
                    changed = True
                    if not m.check_mode:
                        cur.execute(Path(m.params["schema"]).read_text(), prepare=False)
                        counts = []
                        for table in TABLES:
                            cur.execute(
                                sql.SQL("SELECT count(*) FROM {}").format(
                                    sql.Identifier(table)
                                )
                            )
                            counts.append(cur.fetchone()[0])
                        if not any(counts):
                            for table, rows in seed_rows(m.params["fixtures"]).items():
                                cur.execute(
                                    "SELECT column_name FROM information_schema.columns WHERE table_schema=%s AND table_name=%s",
                                    ("public", table),
                                )
                                valid = {x[0] for x in cur.fetchall()}
                                for row in rows:
                                    row = {k: v for k, v in row.items() if k in valid}
                                    cols = list(row)
                                    cur.execute(
                                        sql.SQL(
                                            "INSERT INTO {} ({}) VALUES ({})"
                                        ).format(
                                            sql.Identifier(table),
                                            sql.SQL(",").join(
                                                map(sql.Identifier, cols)
                                            ),
                                            sql.SQL(",").join(
                                                sql.Placeholder() for _ in cols
                                            ),
                                        ),
                                        [row[x] for x in cols],
                                    )
                                cur.execute(
                                    sql.SQL(
                                        "SELECT setval(pg_get_serial_sequence(%s,'id'), GREATEST(COALESCE(MAX(id),1),1), MAX(id) IS NOT NULL) FROM {}"
                                    ).format(sql.Identifier(table)),
                                    (table,),
                                )
                        cur.execute("INSERT INTO zt_migrations VALUES ('baseline-v1')")
                if "roles" in m.params["features"]:
                    for role in ["viewer-read", "support-read", "admin-read"] + (
                        ["support-write"] if "ciba" in m.params["features"] else []
                    ):
                        cur.execute("SELECT 1 FROM pg_roles WHERE rolname=%s", (role,))
                        if not cur.fetchone():
                            changed = True
                            if not m.check_mode:
                                cur.execute(
                                    sql.SQL("CREATE ROLE {} NOLOGIN").format(
                                        sql.Identifier(role)
                                    )
                                )
                            else:
                                continue
                        cur.execute(
                            "SELECT has_schema_privilege(%s,'public','USAGE')", (role,)
                        )
                        if not cur.fetchone()[0]:
                            changed = True
                            if not m.check_mode:
                                cur.execute(
                                    sql.SQL(
                                        "GRANT USAGE ON SCHEMA public TO {}"
                                    ).format(sql.Identifier(role))
                                )
                        tables = (
                            ["users", "orders"]
                            if role == "viewer-read"
                            else (["orders"] if role == "support-write" else TABLES)
                        )
                        for table in tables:
                            for privilege in (
                                ["SELECT", "UPDATE"]
                                if role == "support-write"
                                else ["SELECT"]
                            ):
                                cur.execute(
                                    "SELECT has_table_privilege(%s,%s,%s)",
                                    (role, table, privilege),
                                )
                                if not cur.fetchone()[0]:
                                    changed = True
                                    if not m.check_mode:
                                        cur.execute(
                                            sql.SQL("GRANT {} ON {} TO {}").format(
                                                sql.SQL(privilege),
                                                sql.Identifier(table),
                                                sql.Identifier(role),
                                            )
                                        )
                    cur.execute(
                        "SELECT relrowsecurity FROM pg_class WHERE oid='public.orders'::regclass"
                    )
                    if not cur.fetchone()[0]:
                        changed = True
                        if not m.check_mode:
                            cur.execute("ALTER TABLE orders ENABLE ROW LEVEL SECURITY")
                    policies = [
                        (
                            "orders_viewer_policy",
                            "viewer-read",
                            "SELECT",
                            "classification = 'public'",
                        ),
                        (
                            "orders_support_policy",
                            "support-read",
                            "SELECT",
                            "classification IN ('public', 'internal')",
                        ),
                        ("orders_admin_policy", "admin-read", "SELECT", "true"),
                    ]
                    if "ciba" in m.params["features"]:
                        policies.append(
                            (
                                "orders_support_write_policy",
                                "support-write",
                                "ALL",
                                "classification IN ('public', 'internal')",
                            )
                        )
                    for name, role, command, condition in policies:
                        # Compare canonical PostgreSQL expression by a savepoint-backed temporary policy.
                        cur.execute(
                            "SELECT policyname,roles,cmd,qual,with_check FROM pg_policies WHERE schemaname=%s AND tablename=%s AND policyname=%s",
                            ("public", "orders", name),
                        )
                        current = cur.fetchone()
                        statement = sql.SQL(
                            "CREATE POLICY {} ON orders FOR {} TO {} USING ({}){}"
                        ).format(
                            sql.Identifier(name),
                            sql.SQL(command),
                            sql.Identifier(role),
                            sql.SQL(condition),
                            sql.SQL(
                                " WITH CHECK (" + condition + ")"
                                if command == "ALL"
                                else ""
                            ),
                        )
                        if current is None:
                            changed = True
                            if not m.check_mode:
                                cur.execute(statement)
                        elif current[1] != [role] or current[2] != command:
                            m.fail_json(
                                msg="Existing RLS policy has incompatible ownership/command; inspect it before adoption"
                            )
                        else:
                            # pg_policies uses PostgreSQL's canonical expression spelling.
                            expected = {
                                "viewer-read": "(classification = 'public'::text)",
                                "support-read": "(classification = ANY (ARRAY['public'::text, 'internal'::text]))",
                                "admin-read": "true",
                                "support-write": "(classification = ANY (ARRAY['public'::text, 'internal'::text]))",
                            }[role]
                            normalize = lambda value: "".join((value or "").split())
                            if normalize(current[3]) != normalize(expected) or (
                                command == "ALL"
                                and normalize(current[4]) != normalize(expected)
                            ):
                                changed = True
                                if not m.check_mode:
                                    cur.execute(
                                        sql.SQL("DROP POLICY {} ON orders").format(
                                            sql.Identifier(name)
                                        )
                                    )
                                    cur.execute(statement)
                for table in TABLES:
                    cur.execute("SELECT to_regclass(%s)", ("public." + table,))
                    if not cur.fetchone()[0] and not m.check_mode:
                        m.fail_json(msg="Required application table is missing")
        m.exit_json(changed=changed)
    except Exception as exc:
        m.fail_json(
            msg="Database reconciliation failed ("
            + type(exc).__name__
            + "); transaction rolled back, secret diagnostics withheld"
        )


if __name__ == "__main__":
    main()
