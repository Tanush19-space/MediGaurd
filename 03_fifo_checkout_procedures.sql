CREATE OR REPLACE FUNCTION fn_get_available_fifo_stock(p_medicine_id INT)
RETURNS INT
LANGUAGE SQL
STABLE
AS $$
    SELECT COALESCE(SUM(current_stock), 0)::INT
    FROM inventory_batches
    WHERE medicine_id = p_medicine_id
      AND current_stock > 0
      AND is_locked = FALSE
      AND expiry_status = 'ACTIVE'
      AND (expiry_date - CURRENT_DATE) > 30
$$;

CREATE OR REPLACE PROCEDURE sp_process_fifo_sale(
    IN p_customer_name VARCHAR(150),
    IN p_items JSONB,
    OUT p_sale_id INT,
    OUT p_total_amount NUMERIC(12, 2)
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    v_item JSONB;
    v_medicine_id INT;
    v_requested_qty INT;
    v_remaining_qty INT;
    v_deduct_qty INT;
    v_unit_price NUMERIC(10, 2);
    v_line_subtotal NUMERIC(12, 2);
    v_batch RECORD;
BEGIN
    IF p_customer_name IS NULL OR btrim(p_customer_name) = '' THEN
        RAISE EXCEPTION 'Customer name is required';
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'Sale items must be a non-empty JSON array';
    END IF;

    INSERT INTO sales_transactions (customer_name, total_amount)
    VALUES (btrim(p_customer_name), 0.00)
    RETURNING sale_id INTO p_sale_id;
    p_total_amount := 0.00;

    FOR v_item IN
        SELECT value
        FROM jsonb_array_elements(p_items) AS cart_item(value)
        ORDER BY value ->> 'medicine_id'
    LOOP
        IF jsonb_typeof(v_item) <> 'object'
           OR NOT (v_item ? 'medicine_id')
           OR NOT (v_item ? 'quantity') THEN
            RAISE EXCEPTION 'Each cart item must contain medicine_id and quantity: %', v_item;
        END IF;

        BEGIN
            v_medicine_id := (v_item ->> 'medicine_id')::INT;
            v_requested_qty := (v_item ->> 'quantity')::INT;
        EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
            RAISE EXCEPTION 'medicine_id and quantity must be valid integers: %', v_item;
        END;

        IF v_medicine_id IS NULL OR v_requested_qty IS NULL OR v_requested_qty <= 0 THEN
            RAISE EXCEPTION 'Cart item medicine_id must exist and quantity must be greater than zero: %', v_item;
        END IF;

        SELECT unit_price INTO v_unit_price
        FROM medicines
        WHERE medicine_id = v_medicine_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Medicine ID % not found', v_medicine_id;
        END IF;

        v_remaining_qty := v_requested_qty;

        FOR v_batch IN
            SELECT batch_id, current_stock
            FROM inventory_batches
            WHERE medicine_id = v_medicine_id
              AND current_stock > 0
              AND is_locked = FALSE
              AND expiry_status = 'ACTIVE'
              AND (expiry_date - CURRENT_DATE) > 30
            ORDER BY expiry_date ASC, batch_id ASC
            FOR UPDATE
        LOOP
            EXIT WHEN v_remaining_qty = 0;

            v_deduct_qty := LEAST(v_batch.current_stock, v_remaining_qty);
            v_line_subtotal := ROUND(v_deduct_qty * v_unit_price, 2);

            UPDATE inventory_batches
            SET current_stock = current_stock - v_deduct_qty
            WHERE batch_id = v_batch.batch_id;

            INSERT INTO sale_items (sale_id, batch_id, quantity_sold, unit_price, subtotal)
            VALUES (p_sale_id, v_batch.batch_id, v_deduct_qty, v_unit_price, v_line_subtotal);

            p_total_amount := p_total_amount + v_line_subtotal;
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
END;
$$;

CREATE OR REPLACE PROCEDURE sp_safe_fifo_checkout(
    IN p_customer_name VARCHAR(150),
    IN p_items JSONB,
    INOUT p_status TEXT,
    INOUT p_sale_id INT,
    INOUT p_total NUMERIC(12, 2)
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
    -- This exception block provides savepoint semantics for PL/pgSQL.
    BEGIN
        CALL sp_process_fifo_sale(p_customer_name, p_items, p_sale_id, p_total);
        p_status := 'COMMITTED';
    EXCEPTION WHEN OTHERS THEN
        p_sale_id := NULL;
        p_total := 0.00;
        p_status := 'ROLLED_BACK: ' || SQLERRM;
    END;
END;
$$;

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

GRANT SELECT ON suppliers, medicines, inventory_batches, sales_transactions, sale_items
    TO mediguard_pharmacist, mediguard_auditor;
GRANT EXECUTE ON FUNCTION fn_get_available_fifo_stock(INT)
    TO mediguard_hr_admin, mediguard_pharmacist, mediguard_auditor;
REVOKE ALL ON PROCEDURE sp_process_fifo_sale(VARCHAR, JSONB) FROM PUBLIC;
REVOKE ALL ON PROCEDURE sp_safe_fifo_checkout(VARCHAR, JSONB, TEXT, INT, NUMERIC) FROM PUBLIC;
REVOKE ALL ON PROCEDURE sp_refresh_all_batch_expiry_statuses() FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE sp_process_fifo_sale(VARCHAR, JSONB)
    TO mediguard_hr_admin, mediguard_pharmacist;
GRANT EXECUTE ON PROCEDURE sp_safe_fifo_checkout(VARCHAR, JSONB, TEXT, INT, NUMERIC)
    TO mediguard_hr_admin, mediguard_pharmacist;
GRANT EXECUTE ON PROCEDURE sp_refresh_all_batch_expiry_statuses()
    TO mediguard_hr_admin, mediguard_pharmacist;
