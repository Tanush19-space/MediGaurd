import os
import uuid
from contextlib import contextmanager

import psycopg
from flask import Flask, g, jsonify, render_template, request
from psycopg import sql
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from demo import DemoError, demo_store


app = Flask(__name__, static_folder="static", template_folder="templates")

ROLES = {
    "admin": "mediguard_hr_admin",
    "pharmacist": "mediguard_pharmacist",
    "auditor": "mediguard_auditor",
}

REPORTS = {
    "A": """
        SELECT ib.batch_id, ib.batch_code, m.medicine_name, m.manufacturer,
               s.supplier_name, ib.expiry_date,
               ib.expiry_date - CURRENT_DATE AS days_to_expiry,
               ib.expiry_status, ib.is_locked, ib.current_stock,
               ROUND(ib.current_stock * m.unit_price, 2) AS stock_value_at_risk
        FROM inventory_batches ib
        JOIN medicines m ON m.medicine_id = ib.medicine_id
        JOIN suppliers s ON s.supplier_id = ib.supplier_id
        WHERE ib.current_stock > 0
          AND (ib.expiry_date <= CURRENT_DATE + 30 OR ib.is_locked)
        ORDER BY ib.expiry_date, stock_value_at_risk DESC
    """,
    "B": """
        SELECT m.medicine_id, m.medicine_name, m.category, m.unit_price,
               COALESCE(SUM(ib.current_stock), 0) AS sellable_fifo_units,
               MIN(ib.expiry_date) AS next_dispensable_expiry,
               COALESCE(SUM(ib.current_stock * m.unit_price), 0.00) AS sellable_inventory_value
        FROM medicines m
        LEFT JOIN inventory_batches ib
          ON ib.medicine_id = m.medicine_id
         AND ib.current_stock > 0
         AND ib.is_locked = FALSE
         AND ib.expiry_status = 'ACTIVE'
         AND ib.expiry_date - CURRENT_DATE > 30
        GROUP BY m.medicine_id, m.medicine_name, m.category, m.unit_price
        ORDER BY m.medicine_name
    """,
    "C": """
        SELECT st.sale_id, st.sale_date, st.customer_name, m.medicine_name,
               ib.batch_code, ib.expiry_date, s.supplier_name,
               si.quantity_sold, si.unit_price, si.subtotal, st.total_amount
        FROM sales_transactions st
        JOIN sale_items si ON si.sale_id = st.sale_id
        JOIN inventory_batches ib ON ib.batch_id = si.batch_id
        JOIN medicines m ON m.medicine_id = ib.medicine_id
        JOIN suppliers s ON s.supplier_id = ib.supplier_id
        WHERE st.sale_date >= CURRENT_DATE - 30
        ORDER BY st.sale_date DESC, st.sale_id DESC, si.item_id
    """,
}

PLAN_QUERY = """
    SELECT batch_id, batch_code, expiry_date, current_stock
    FROM inventory_batches
    WHERE current_stock > 0
      AND (expiry_date <= CURRENT_DATE + 30 OR is_locked)
    ORDER BY expiry_date
"""


class DatabaseConfigurationError(Exception):
    pass


class RollbackQA(Exception):
    pass


def demo_mode():
    configured = os.environ.get("MEDIGUARD_DEMO_MODE")
    if configured is not None:
        return configured.strip().lower() in ("1", "true", "yes", "on")
    return not bool(os.environ.get("MEDIGUARD_DATABASE_URL"))


def active_role():
    role = request.headers.get("X-MediGuard-Role", "pharmacist")
    if role not in ROLES:
        return None
    return role


@contextmanager
def database(role):
    database_url = os.environ.get("MEDIGUARD_DATABASE_URL")
    if not database_url:
        raise DatabaseConfigurationError(
            "Set MEDIGUARD_DATABASE_URL to connect to the PostgreSQL database."
        )

    conn = psycopg.connect(database_url, row_factory=dict_row)
    try:
        with conn.transaction():
            conn.execute(
                sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(ROLES[role]))
            )
            yield conn
    finally:
        conn.close()


def require_role(*allowed_roles):
    role = active_role()
    if role is None:
        return None, (jsonify(error="Unknown RBAC role."), 400)
    if role not in allowed_roles:
        return None, (
            jsonify(
                error="Action blocked by RBAC.",
                active_role=role,
                allowed_roles=list(allowed_roles),
            ),
            403,
        )
    return role, None


@app.errorhandler(DatabaseConfigurationError)
def handle_database_configuration(error):
    return jsonify(error=str(error)), 503


@app.errorhandler(DemoError)
def handle_demo_error(error):
    return (
        jsonify(
            error=str(error),
            detail=str(error),
            sql=getattr(g, "sql_statement", None),
            demo=True,
        ),
        error.status_code,
    )


@app.errorhandler(psycopg.Error)
def handle_database_error(error):
    message = error.diag.message_primary if error.diag and error.diag.message_primary else str(error)
    return (
        jsonify(
            error=message,
            detail=str(error),
            sqlstate=error.sqlstate,
            sql=getattr(g, "sql_statement", None),
        ),
        409 if error.sqlstate in ("23505", "23514", "P0001") else 500,
    )


@app.get("/")
def home():
    return render_template("index.html")


@app.get("/api/health")
def health():
    role = active_role()
    if role is None:
        return jsonify(error="Unknown RBAC role."), 400
    if demo_mode():
        return jsonify(demo_store.health())
    try:
        with database(role) as conn:
            row = conn.execute(
                "SELECT current_database() AS database, current_user AS active_database_role"
            ).fetchone()
        return jsonify(connected=True, **row)
    except (DatabaseConfigurationError, psycopg.Error) as error:
        message = error.diag.message_primary if isinstance(error, psycopg.Error) and error.diag and error.diag.message_primary else str(error)
        return jsonify(connected=False, error=message), 503


@app.get("/api/overview")
def overview():
    role = active_role()
    if role is None:
        return jsonify(error="Unknown RBAC role."), 400
    if demo_mode():
        return jsonify(demo=True, **demo_store.overview())
    with database(role) as conn:
        metrics = conn.execute(
            """
            SELECT
                (SELECT COUNT(*) FROM medicines) AS medicines,
                (SELECT COUNT(*) FROM inventory_batches) AS batches,
                (SELECT COALESCE(SUM(current_stock), 0) FROM inventory_batches) AS units,
                (SELECT COUNT(*) FROM inventory_batches
                 WHERE current_stock > 0 AND is_locked) AS locked_batches,
                (SELECT COUNT(*) FROM sales_transactions
                 WHERE sale_date >= CURRENT_DATE) AS sales_today
            """
        ).fetchone()
        batches = conn.execute(
            """
            SELECT ib.batch_id, ib.batch_code, m.medicine_name, ib.expiry_date,
                   ib.expiry_date - CURRENT_DATE AS days_to_expiry,
                   ib.expiry_status, ib.is_locked, ib.current_stock
            FROM inventory_batches ib
            JOIN medicines m ON m.medicine_id = ib.medicine_id
            ORDER BY ib.expiry_date, ib.batch_id
            LIMIT 8
            """
        ).fetchall()
    return jsonify(metrics=metrics, batches=batches)


@app.get("/api/catalog")
def catalog():
    role = active_role()
    if role is None:
        return jsonify(error="Unknown RBAC role."), 400
    if demo_mode():
        return jsonify(demo=True, **demo_store.catalog())
    with database(role) as conn:
        rows = conn.execute(
            """
            SELECT m.medicine_id, m.medicine_name, m.manufacturer, m.category,
                   m.unit_price,
                   fn_get_available_fifo_stock(m.medicine_id) AS available_stock
            FROM medicines m
            ORDER BY m.medicine_name
            """
        ).fetchall()
    return jsonify(medicines=rows)


@app.get("/api/suppliers")
def supplier_catalog():
    role = active_role()
    if role is None:
        return jsonify(error="Unknown RBAC role."), 400
    if demo_mode():
        return jsonify(demo=True, **demo_store.suppliers_list())
    with database(role) as conn:
        rows = conn.execute(
            "SELECT supplier_id, supplier_name FROM suppliers ORDER BY supplier_name"
        ).fetchall()
    return jsonify(suppliers=rows)


@app.get("/api/batches")
def batches():
    role = active_role()
    if role is None:
        return jsonify(error="Unknown RBAC role."), 400
    if demo_mode():
        return jsonify(demo=True, **demo_store.batches_list())
    with database(role) as conn:
        rows = conn.execute(
            """
            SELECT ib.batch_id, ib.batch_code, ib.medicine_id, m.medicine_name,
                   ib.supplier_id, s.supplier_name, ib.manufacture_date,
                   ib.expiry_date, ib.expiry_date - CURRENT_DATE AS days_to_expiry,
                   ib.quantity_received, ib.current_stock, ib.expiry_status,
                   ib.is_locked, ib.updated_at
            FROM inventory_batches ib
            JOIN medicines m ON m.medicine_id = ib.medicine_id
            JOIN suppliers s ON s.supplier_id = ib.supplier_id
            ORDER BY ib.expiry_date, ib.batch_id
            """
        ).fetchall()
    return jsonify(batches=rows)


@app.post("/api/batches")
def add_batch():
    role, denied = require_role("admin")
    if denied:
        return denied
    data = request.get_json(silent=True) or {}
    required = (
        "medicine_id",
        "supplier_id",
        "batch_code",
        "manufacture_date",
        "expiry_date",
        "quantity_received",
        "current_stock",
    )
    if any(data.get(field) in (None, "") for field in required):
        return jsonify(error="Complete every batch field before saving."), 400

    g.sql_statement = "INSERT INTO inventory_batches (...) VALUES (...)"
    if demo_mode():
        return jsonify(
            demo=True,
            batch=demo_store.add_batch(data)["batch"],
            sql="SIMULATED: INSERT INTO inventory_batches (...) VALUES (...)",
            message="Demo batch added; no database was changed.",
        ), 201
    with database(role) as conn:
        row = conn.execute(
            """
            INSERT INTO inventory_batches
                (medicine_id, supplier_id, batch_code, manufacture_date,
                 expiry_date, quantity_received, current_stock)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            RETURNING batch_id, batch_code, expiry_status, is_locked, current_stock
            """,
            tuple(data[field] for field in required),
        ).fetchone()
    return jsonify(batch=row, sql="INSERT INTO inventory_batches (...) VALUES (...)", message="Batch added."), 201


@app.post("/api/batches/<int:batch_id>/unlock")
def unlock_batch(batch_id):
    role, denied = require_role("admin")
    if denied:
        return denied
    g.sql_statement = "UPDATE inventory_batches SET is_locked = FALSE WHERE batch_id = %s"
    if demo_mode():
        result = demo_store.unlock(batch_id)
        return jsonify(
            demo=True,
            **result,
            sql="SIMULATED: UPDATE inventory_batches SET is_locked = FALSE WHERE batch_id = %s",
        )
    with database(role) as conn:
        row = conn.execute(
            """
            UPDATE inventory_batches
            SET is_locked = FALSE
            WHERE batch_id = %s
            RETURNING batch_id, batch_code, expiry_status, is_locked
            """,
            (batch_id,),
        ).fetchone()
        if row is None:
            return jsonify(error=f"Batch {batch_id} was not found."), 404
    return jsonify(batch=row, sql="UPDATE inventory_batches SET is_locked = FALSE WHERE batch_id = %s")


@app.post("/api/checkout")
def checkout():
    role, denied = require_role("admin", "pharmacist")
    if denied:
        return denied
    data = request.get_json(silent=True) or {}
    customer_name = data.get("customer_name", "")
    items = data.get("items")
    if not isinstance(customer_name, str) or not customer_name.strip():
        return jsonify(error="Customer name is required."), 400
    if not isinstance(items, list) or not items:
        return jsonify(error="Add at least one item to the cart."), 400

    g.sql_statement = "CALL sp_safe_fifo_checkout(customer, items, ...)"
    if demo_mode():
        try:
            result = demo_store.checkout(customer_name, items)
        except DemoError as error:
            return jsonify(
                error=str(error),
                sql="SIMULATED: CALL sp_safe_fifo_checkout(customer, items, ...)",
                transaction="ROLLED_BACK",
                demo=True,
            ), 409
        return jsonify(
            **result,
            demo=True,
            sql="SIMULATED: CALL sp_safe_fifo_checkout(customer, items, ...)",
            transaction="COMMITTED",
        )
    with database(role) as conn:
        result = conn.execute(
            "CALL sp_safe_fifo_checkout(%s, %s, NULL, NULL, NULL)",
            (customer_name.strip(), Jsonb(items)),
        ).fetchone()
        if result["p_status"] != "COMMITTED":
            return (
                jsonify(
                    error=result["p_status"],
                    sql="CALL sp_safe_fifo_checkout(customer, items, ...)",
                    transaction="ROLLED_BACK",
                ),
                409,
            )
        sale_id = result["p_sale_id"]
        details = conn.execute(
            """
            SELECT si.batch_id, ib.batch_code, m.medicine_name,
                   si.quantity_sold, si.unit_price, si.subtotal
            FROM sale_items si
            JOIN inventory_batches ib ON ib.batch_id = si.batch_id
            JOIN medicines m ON m.medicine_id = ib.medicine_id
            WHERE si.sale_id = %s
            ORDER BY si.item_id
            """,
            (sale_id,),
        ).fetchall()
    return jsonify(
        sale_id=sale_id,
        total=result["p_total"],
        items=details,
        sql="CALL sp_safe_fifo_checkout(customer, items, ...)",
        transaction="COMMITTED",
    )


@app.post("/api/refresh")
def refresh_expiry():
    role, denied = require_role("admin", "pharmacist")
    if denied:
        return denied
    g.sql_statement = "CALL sp_refresh_all_batch_expiry_statuses()"
    if demo_mode():
        return jsonify(
            demo=True,
            **demo_store.refresh_expiry(),
            sql="SIMULATED: CALL sp_refresh_all_batch_expiry_statuses()",
        )
    with database(role) as conn:
        conn.execute("CALL sp_refresh_all_batch_expiry_statuses()")
        count = conn.execute("SELECT COUNT(*) AS refreshed FROM inventory_batches").fetchone()["refreshed"]
    return jsonify(refreshed=count, sql="CALL sp_refresh_all_batch_expiry_statuses()")


@app.get("/api/reports/<report_id>")
def report(report_id):
    role = active_role()
    if role is None:
        return jsonify(error="Unknown RBAC role."), 400
    query = REPORTS.get(report_id.upper())
    if query is None:
        return jsonify(error="Choose Report A, B, or C."), 404
    g.sql_statement = query.strip()
    if demo_mode():
        return jsonify(
            demo=True,
            report=report_id.upper(),
            rows=demo_store.report(report_id.upper()),
            sql="SIMULATED REPORT QUERY — no SQL executed.",
        )
    with database(role) as conn:
        rows = conn.execute(query).fetchall()
    return jsonify(report=report_id.upper(), rows=rows, sql=query.strip())


@app.get("/api/plans")
def plans():
    role = active_role()
    if role is None:
        return jsonify(error="Unknown RBAC role."), 400
    g.sql_statement = "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + PLAN_QUERY.strip()
    if demo_mode():
        return jsonify(
            demo=True,
            **demo_store.plans(),
            sql="SIMULATED EXPLAIN — sample plan; no database was queried.",
        )
    with database(role) as conn:
        conn.execute("SET LOCAL enable_indexscan = OFF")
        conn.execute("SET LOCAL enable_indexonlyscan = OFF")
        conn.execute("SET LOCAL enable_bitmapscan = OFF")
        baseline = conn.execute(
            "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + PLAN_QUERY
        ).fetchone()["QUERY PLAN"][0]
        conn.execute("SET LOCAL enable_indexscan = ON")
        conn.execute("SET LOCAL enable_indexonlyscan = ON")
        conn.execute("SET LOCAL enable_bitmapscan = ON")
        conn.execute("SET LOCAL enable_seqscan = OFF")
        optimized = conn.execute(
            "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + PLAN_QUERY
        ).fetchone()["QUERY PLAN"][0]
    return jsonify(
        baseline=baseline,
        optimized=optimized,
        sql=PLAN_QUERY.strip(),
        note="The baseline disables index paths. The index demonstration disables sequential scans to expose the available index path; compare it with normal production plans before drawing performance conclusions.",
    )


@app.post("/api/qa")
def run_qa():
    role, denied = require_role("admin")
    if denied:
        return denied
    g.sql_statement = "QA fixture transaction: seed, TC-01 through TC-06, ROLLBACK"
    if demo_mode():
        return jsonify(demo=True, **demo_store.qa())
    token = uuid.uuid4().hex[:12].upper()
    steps = []

    def record(test_id, title, passed, detail):
        steps.append(
            {
                "id": test_id,
                "title": title,
                "passed": passed,
                "detail": detail,
            }
        )

    with database(role) as conn:
        try:
            with conn.transaction():
                supplier_a = conn.execute(
                    """
                    INSERT INTO suppliers (supplier_name, license_number)
                    VALUES (%s, %s) RETURNING supplier_id
                    """,
                    (f"QA Supplier A {token}", f"MG-QA-A-{token}"),
                ).fetchone()["supplier_id"]
                supplier_b = conn.execute(
                    """
                    INSERT INTO suppliers (supplier_name, license_number)
                    VALUES (%s, %s) RETURNING supplier_id
                    """,
                    (f"QA Supplier B {token}", f"MG-QA-B-{token}"),
                ).fetchone()["supplier_id"]
                medicine_a = conn.execute(
                    """
                    INSERT INTO medicines (medicine_name, manufacturer, category, unit_price)
                    VALUES (%s, 'QA Lab', 'QA', 10.00) RETURNING medicine_id
                    """,
                    (f"QA Medicine A {token}",),
                ).fetchone()["medicine_id"]
                medicine_b = conn.execute(
                    """
                    INSERT INTO medicines (medicine_name, manufacturer, category, unit_price)
                    VALUES (%s, 'QA Lab', 'QA', 5.00) RETURNING medicine_id
                    """,
                    (f"QA Medicine B {token}",),
                ).fetchone()["medicine_id"]

                def add_fixture(medicine_id, supplier_id, code, days, qty):
                    return conn.execute(
                        """
                        INSERT INTO inventory_batches
                            (medicine_id, supplier_id, batch_code, manufacture_date,
                             expiry_date, quantity_received, current_stock)
                        VALUES (%s, %s, %s, CURRENT_DATE - 60,
                                CURRENT_DATE + %s, %s, %s)
                        RETURNING batch_id
                        """,
                        (medicine_id, supplier_id, f"{code}-{token}", days, qty, qty),
                    ).fetchone()["batch_id"]

                add_fixture(medicine_a, supplier_a, "EXPIRED", -5, 30)
                batch_30 = add_fixture(medicine_a, supplier_a, "BOUNDARY-30", 30, 25)
                batch_31 = add_fixture(medicine_a, supplier_a, "BOUNDARY-31", 31, 20)
                batch_180 = add_fixture(medicine_a, supplier_b, "FIFO-180", 180, 50)
                batch_low = add_fixture(medicine_b, supplier_b, "LOW-STOCK", 90, 10)

                result = conn.execute(
                    "SELECT expiry_status, is_locked FROM inventory_batches WHERE batch_id = %s",
                    (batch_30,),
                ).fetchone()
                passed = result["expiry_status"] == "EXPIRING_SOON" and result["is_locked"]
                record("TC-01", "30-day safety boundary", passed, f"{result['expiry_status']} / locked={result['is_locked']}")

                result = conn.execute(
                    "SELECT expiry_status, is_locked FROM inventory_batches WHERE batch_id = %s",
                    (batch_31,),
                ).fetchone()
                passed = result["expiry_status"] == "ACTIVE" and not result["is_locked"]
                record("TC-02", "31-day sellable boundary", passed, f"{result['expiry_status']} / locked={result['is_locked']}")

                blocked = False
                try:
                    with conn.transaction():
                        conn.execute(
                            "UPDATE inventory_batches SET is_locked = FALSE WHERE batch_id = %s",
                            (batch_30,),
                        )
                except psycopg.Error as error:
                    blocked = True
                    unlock_error = error.diag.message_primary if error.diag else str(error)
                record(
                    "TC-03",
                    "Blocked unsafe unlock",
                    blocked,
                    unlock_error if blocked else "Unlock unexpectedly succeeded.",
                )

                invalid_date_rejected = False
                try:
                    with conn.transaction():
                        conn.execute(
                            """
                            INSERT INTO inventory_batches
                                (medicine_id, supplier_id, batch_code, manufacture_date,
                                 expiry_date, quantity_received, current_stock)
                            VALUES (%s, %s, %s, CURRENT_DATE, CURRENT_DATE, 5, 5)
                            """,
                            (medicine_a, supplier_a, f"INVALID-{token}"),
                        )
                except psycopg.Error as error:
                    invalid_date_rejected = True
                    date_error = error.diag.message_primary if error.diag else str(error)
                record(
                    "TC-04",
                    "Invalid shelf-life rejection",
                    invalid_date_rejected,
                    date_error if invalid_date_rejected else "Invalid dates unexpectedly succeeded.",
                )

                sale = conn.execute(
                    """
                    CALL sp_process_fifo_sale(%s, %s, NULL, NULL)
                    """,
                    (
                        f"QA FIFO {token}",
                        Jsonb([{"medicine_id": medicine_a, "quantity": 35}]),
                    ),
                ).fetchone()
                first_stock = conn.execute(
                    "SELECT current_stock FROM inventory_batches WHERE batch_id = %s",
                    (batch_31,),
                ).fetchone()["current_stock"]
                second_stock = conn.execute(
                    "SELECT current_stock FROM inventory_batches WHERE batch_id = %s",
                    (batch_180,),
                ).fetchone()["current_stock"]
                passed = (
                    sale["p_total_amount"] == 350
                    and first_stock == 0
                    and second_stock == 35
                )
                record(
                    "TC-05",
                    "Multi-batch FIFO checkout",
                    passed,
                    f"sale #{sale['p_sale_id']} total={sale['p_total_amount']}; batches={first_stock}+{second_stock}",
                )

                insufficient_rejected = False
                try:
                    with conn.transaction():
                        conn.execute(
                            "CALL sp_process_fifo_sale(%s, %s, NULL, NULL)",
                            (
                                f"QA Oversell {token}",
                                Jsonb([{"medicine_id": medicine_b, "quantity": 25}]),
                            ),
                        )
                except psycopg.Error as error:
                    insufficient_rejected = True
                    stock_error = error.diag.message_primary if error.diag else str(error)
                low_stock = conn.execute(
                    "SELECT current_stock FROM inventory_batches WHERE batch_id = %s",
                    (batch_low,),
                ).fetchone()["current_stock"]
                grants = conn.execute(
                    """
                    SELECT
                        has_table_privilege('mediguard_auditor', 'inventory_batches', 'SELECT')
                            AND NOT has_table_privilege('mediguard_auditor', 'inventory_batches', 'UPDATE')
                            AND NOT has_table_privilege('mediguard_auditor', 'sales_transactions', 'DELETE')
                            AND NOT has_table_privilege('mediguard_pharmacist', 'inventory_batches', 'UPDATE')
                            AND NOT has_table_privilege('mediguard_pharmacist', 'inventory_batches', 'DELETE')
                            AND NOT has_table_privilege('mediguard_pharmacist', 'sales_transactions', 'DELETE')
                            AS least_privilege
                    """
                ).fetchone()["least_privilege"]
                passed = insufficient_rejected and low_stock == 10 and grants
                detail = (
                    f"{stock_error}; stock remains {low_stock}; role grants "
                    f"{'pass' if grants else 'fail'}."
                    if insufficient_rejected
                    else f"Oversell unexpectedly succeeded; stock={low_stock}; grants={grants}."
                )
                record("TC-06", "Rollback and RBAC enforcement", passed, detail)
                raise RollbackQA()
        except RollbackQA:
            pass

    return jsonify(
        steps=steps,
        passed=sum(1 for step in steps if step["passed"]),
        total=len(steps),
        rolled_back=True,
    )


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=int(os.environ.get("PORT", "5000")))
