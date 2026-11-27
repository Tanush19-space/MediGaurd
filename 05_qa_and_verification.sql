-- Runs in a transaction and rolls back all fixture data at the end.
BEGIN;

DO $$
DECLARE
    v_supplier_a INT;
    v_supplier_b INT;
    v_medicine_a INT;
    v_medicine_b INT;
    v_batch_31 INT;
    v_batch_180 INT;
    v_batch_low INT;
    v_status VARCHAR(20);
    v_locked BOOLEAN;
    v_stock INT;
    v_sale_id INT;
    v_total NUMERIC(12, 2);
    v_failed BOOLEAN;
BEGIN
    INSERT INTO suppliers (supplier_name, license_number)
    VALUES ('MediGuard QA Supplier A', 'MG-QA-SUPPLIER-A')
    RETURNING supplier_id INTO v_supplier_a;
    INSERT INTO suppliers (supplier_name, license_number)
    VALUES ('MediGuard QA Supplier B', 'MG-QA-SUPPLIER-B')
    RETURNING supplier_id INTO v_supplier_b;
    INSERT INTO medicines (medicine_name, manufacturer, category, unit_price)
    VALUES ('MediGuard QA Medicine A', 'QA Lab', 'QA', 10.00)
    RETURNING medicine_id INTO v_medicine_a;
    INSERT INTO medicines (medicine_name, manufacturer, category, unit_price)
    VALUES ('MediGuard QA Medicine B', 'QA Lab', 'QA', 5.00)
    RETURNING medicine_id INTO v_medicine_b;

    INSERT INTO inventory_batches
        (medicine_id, supplier_id, batch_code, manufacture_date, expiry_date, quantity_received, current_stock)
    VALUES
        (v_medicine_a, v_supplier_a, 'MG-QA-EXPIRED', CURRENT_DATE - 180, CURRENT_DATE - 5, 30, 30),
        (v_medicine_a, v_supplier_a, 'MG-QA-30D', CURRENT_DATE - 150, CURRENT_DATE + 30, 25, 25),
        (v_medicine_a, v_supplier_a, 'MG-QA-31D', CURRENT_DATE - 120, CURRENT_DATE + 31, 20, 20),
        (v_medicine_a, v_supplier_b, 'MG-QA-180D', CURRENT_DATE - 30, CURRENT_DATE + 180, 50, 50),
        (v_medicine_b, v_supplier_b, 'MG-QA-LOW', CURRENT_DATE - 40, CURRENT_DATE + 90, 10, 10);

    SELECT batch_id INTO v_batch_31 FROM inventory_batches WHERE medicine_id = v_medicine_a AND batch_code = 'MG-QA-31D';
    SELECT batch_id INTO v_batch_180 FROM inventory_batches WHERE medicine_id = v_medicine_a AND batch_code = 'MG-QA-180D';
    SELECT batch_id INTO v_batch_low FROM inventory_batches WHERE medicine_id = v_medicine_b AND batch_code = 'MG-QA-LOW';

    SELECT expiry_status, is_locked INTO v_status, v_locked
    FROM inventory_batches WHERE batch_code = 'MG-QA-30D';
    IF v_status <> 'EXPIRING_SOON' OR v_locked IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION 'TC-01 FAILED: expected EXPIRING_SOON and locked; got % and %', v_status, v_locked;
    END IF;
    RAISE NOTICE 'TC-01 PASSED: exact 30-day batch is EXPIRING_SOON and locked.';

    SELECT expiry_status, is_locked INTO v_status, v_locked
    FROM inventory_batches WHERE batch_id = v_batch_31;
    IF v_status <> 'ACTIVE' OR v_locked IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION 'TC-02 FAILED: expected ACTIVE and unlocked; got % and %', v_status, v_locked;
    END IF;
    RAISE NOTICE 'TC-02 PASSED: 31-day batch is ACTIVE and unlocked.';

    v_failed := FALSE;
    BEGIN
        UPDATE inventory_batches SET is_locked = FALSE WHERE batch_code = 'MG-QA-30D';
    EXCEPTION WHEN raise_exception THEN
        v_failed := TRUE;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'TC-03 FAILED: unlocking a batch inside 30 days was not rejected.';
    END IF;
    RAISE NOTICE 'TC-03 PASSED: trigger rejected an attempt to unlock a 30-day batch.';

    v_failed := FALSE;
    BEGIN
        INSERT INTO inventory_batches
            (medicine_id, supplier_id, batch_code, manufacture_date, expiry_date, quantity_received, current_stock)
        VALUES
            (v_medicine_a, v_supplier_a, 'MG-QA-BAD-DATE', CURRENT_DATE + 10, CURRENT_DATE + 5, 10, 10);
    EXCEPTION WHEN raise_exception OR check_violation THEN
        v_failed := TRUE;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'TC-04 FAILED: invalid shelf-life dates were accepted.';
    END IF;
    RAISE NOTICE 'TC-04 PASSED: invalid shelf-life dates were rejected.';

    CALL sp_process_fifo_sale(
        'MediGuard QA FIFO',
        jsonb_build_array(jsonb_build_object('medicine_id', v_medicine_a, 'quantity', 35)),
        v_sale_id,
        v_total
    );
    IF v_total <> 350.00 THEN
        RAISE EXCEPTION 'TC-05 FAILED: expected total 350.00; got %', v_total;
    END IF;
    SELECT current_stock INTO v_stock FROM inventory_batches WHERE batch_id = v_batch_31;
    IF v_stock <> 0 THEN
        RAISE EXCEPTION 'TC-05 FAILED: expected first FIFO batch stock 0; got %', v_stock;
    END IF;
    SELECT current_stock INTO v_stock FROM inventory_batches WHERE batch_id = v_batch_180;
    IF v_stock <> 35 THEN
        RAISE EXCEPTION 'TC-05 FAILED: expected second FIFO batch stock 35; got %', v_stock;
    END IF;
    RAISE NOTICE 'TC-05 PASSED: FIFO checkout split across batches and charged 350.00.';

    v_failed := FALSE;
    BEGIN
        CALL sp_process_fifo_sale(
            'MediGuard QA insufficient stock',
            jsonb_build_array(jsonb_build_object('medicine_id', v_medicine_b, 'quantity', 25)),
            v_sale_id,
            v_total
        );
    EXCEPTION WHEN raise_exception THEN
        v_failed := TRUE;
    END;
    SELECT current_stock INTO v_stock FROM inventory_batches WHERE batch_id = v_batch_low;
    IF NOT v_failed OR v_stock <> 10 THEN
        RAISE EXCEPTION 'TC-06 FAILED: insufficient stock did not roll back cleanly; rejected=%, stock=%', v_failed, v_stock;
    END IF;
    IF NOT has_table_privilege('mediguard_auditor', 'inventory_batches', 'SELECT')
       OR has_table_privilege('mediguard_auditor', 'inventory_batches', 'UPDATE')
       OR has_table_privilege('mediguard_auditor', 'sales_transactions', 'DELETE')
       OR has_table_privilege('mediguard_pharmacist', 'inventory_batches', 'UPDATE')
       OR has_table_privilege('mediguard_pharmacist', 'inventory_batches', 'DELETE')
       OR has_table_privilege('mediguard_pharmacist', 'sales_transactions', 'DELETE') THEN
        RAISE EXCEPTION 'TC-06 FAILED: role grants do not enforce the expected read/write boundary.';
    END IF;
    RAISE NOTICE 'TC-06 PASSED: insufficient checkout rolled back and RBAC grants are least-privilege.';
END;
$$;

ROLLBACK;
