```sql
-- ============================================================================
-- MEMBER 3: ACID FIFO CHECKOUT FUNCTIONS, PROCEDURES & RBAC ROLES
-- File: sql/03_fifo_checkout_procedures.sql
-- Target DBMS: PostgreSQL
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_get_available_fifo_stock(p_medicine_id INT)
RETURNS INT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_total_available INT;
BEGIN
    IF p_medicine_id IS NULL THEN
        RAISE EXCEPTION 'medicine_id cannot be NULL';
    END IF;

    PERFORM 1 FROM medicines WHERE medicine_id = p_medicine_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine ID % does not exist', p_medicine_id;
    END IF;

    SELECT COALESCE(SUM(current_stock), 0)
    INTO v_total_available
    FROM inventory_batches
    WHERE medicine_id = p_medicine_id
      AND current_stock > 0
      AND is_locked = FALSE
      AND expiry_status = 'ACTIVE'
      AND (expiry_date - CURRENT_DATE) > 30;

    RETURN v_total_available;
END;
$$;


CREATE OR REPLACE PROCEDURE sp_process_fifo_sale(
    IN p_customer_name VARCHAR(150),
    IN p_items         JSONB,
    OUT p_sale_id      INT,
    OUT p_total_amount NUMERIC(12, 2)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_item            JSONB;
    v_medicine_id     INT;
    v_requested_qty   INT;
    v_remaining_qty   INT;
    v_deduct_qty      INT;
    v_unit_price      NUMERIC(10, 2);
    v_line_subtotal   NUMERIC(12, 2);
    v_batch           RECORD;
BEGIN
    IF p_customer_name IS NULL OR btrim(p_customer_name) = '' THEN
        RAISE EXCEPTION 'Customer name is required';
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'Sale items must be a non-empty JSON array';
    END IF;

    INSERT INTO sales_transactions (customer_name, sale_date, total_amount)
    VALUES (btrim(p_customer_name), CURRENT_TIMESTAMP, 0.00)
    RETURNING sale_id INTO p_sale_id;

    p_total_amount := 0.00;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        v_medicine_id   := (v_item ->> 'medicine_id')::INT;
        v_requested_qty := (v_item ->> 'quantity')::INT;

        IF v_medicine_id IS NULL OR v_requested_qty IS NULL OR v_requested_qty <= 0 THEN
            RAISE EXCEPTION 'Invalid item payload: %', v_item;
        END IF;

        SELECT unit_price INTO v_unit_price
        FROM medicines
        WHERE medicine_id = v_medicine_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Medicine ID % not found', v_medicine_id;
        END IF;

        v_remaining_qty := v_requested_qty;

        FOR v_batch IN
            SELECT batch_id, current_stock, expiry_date
            FROM inventory_batches
            WHERE medicine_id = v_medicine_id
              AND current_stock > 0
              AND is_locked = FALSE
              AND expiry_status = 'ACTIVE'
              AND (expiry_date - CURRENT_DATE) > 30
            ORDER BY expiry_date ASC, batch_id ASC
            FOR UPDATE
        LOOP
            EXIT WHEN v_remaining_qty <= 0;

            v_deduct_qty    := LEAST(v_batch.current_stock, v_remaining_qty);
            v_line_subtotal := ROUND(v_deduct_qty * v_unit_price, 2);

            UPDATE inventory_batches
            SET current_stock = current_stock - v_deduct_qty
            WHERE batch_id = v_batch.batch_id;

            INSERT INTO sale_items (sale_id, batch_id, quantity_sold, unit_price, subtotal)
            VALUES (p_sale_id, v_batch.batch_id, v_deduct_qty, v_unit_price, v_line_subtotal);

            p_total_amount  := p_total_amount + v_line_subtotal;
            v_remaining_qty := v_remaining_qty - v_deduct_qty;
        END LOOP;

        IF v_remaining_qty > 0 THEN
            RAISE EXCEPTION 'Insufficient sellable FIFO stock for medicine_id %: short by % units',
                v_medicine_id, v_remaining_qty;
        END IF;
    END LOOP;

    UPDATE sales_transactions
    SET total_amount = p_total_amount
    WHERE sale_id = p_sale_id;

EXCEPTION
    WHEN OTHERS THEN
        RAISE;
END;
$$;


CREATE OR REPLACE PROCEDURE sp_safe_fifo_checkout(
    IN p_customer_name VARCHAR(150),
    IN p_items         JSONB,
    INOUT p_status     TEXT DEFAULT NULL,
    INOUT p_sale_id    INT  DEFAULT NULL,
    INOUT p_total      NUMERIC(12, 2) DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    SAVEPOINT sp_fifo_sale;

    CALL sp_process_fifo_sale(p_customer_name, p_items, p_sale_id, p_total);

    RELEASE SAVEPOINT sp_fifo_sale;
    p_status := 'COMMITTED';
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK TO SAVEPOINT sp_fifo_sale;
        p_sale_id := NULL;
        p_total   := 0.00;
        p_status  := 'ROLLED_BACK: ' || SQLERRM;
END;
$$;


-- RBAC Roles & Grants
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mediguard_hr_admin') THEN
        CREATE ROLE mediguard_hr_admin NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mediguard_pharmacist') THEN
        CREATE ROLE mediguard_pharmacist NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mediguard_auditor') THEN
        CREATE ROLE mediguard_auditor NOLOGIN;
    END IF;
END;
$$;

GRANT USAGE ON SCHEMA public TO mediguard_hr_admin, mediguard_pharmacist, mediguard_auditor;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO mediguard_hr_admin;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO mediguard_hr_admin;

GRANT SELECT ON suppliers, medicines, inventory_batches, sales_transactions, sale_items TO mediguard_pharmacist;
GRANT INSERT, UPDATE (current_stock, updated_at) ON inventory_batches TO mediguard_pharmacist;
GRANT INSERT, UPDATE (total_amount) ON sales_transactions TO mediguard_pharmacist;
GRANT INSERT ON sale_items TO mediguard_pharmacist;
GRANT USAGE, SELECT ON SEQUENCE inventory_batches_batch_id_seq,
                               sales_transactions_sale_id_seq,
                               sale_items_item_id_seq TO mediguard_pharmacist;

GRANT SELECT ON suppliers, medicines, inventory_batches, sales_transactions, sale_items TO mediguard_auditor;
GRANT EXECUTE ON FUNCTION fn_get_available_fifo_stock(INT) TO mediguard_hr_admin, mediguard_pharmacist, mediguard_auditor;
GRANT EXECUTE ON PROCEDURE sp_process_fifo_sale(VARCHAR, JSONB, INT, NUMERIC) TO mediguard_hr_admin, mediguard_pharmacist;
GRANT EXECUTE ON PROCEDURE sp_safe_fifo_checkout(VARCHAR, JSONB, TEXT, INT, NUMERIC) TO mediguard_hr_admin, mediguard_pharmacist;
GRANT EXECUTE ON PROCEDURE sp_refresh_all_batch_expiry_statuses() TO mediguard_hr_admin, mediguard_pharmacist;
```

---