TRUNCATE TABLE
    sale_items,
    sales_transactions,
    inventory_batches,
    medicines,
    suppliers
RESTART IDENTITY CASCADE;

INSERT INTO suppliers (supplier_name, contact_person, phone, license_number)
VALUES
    ('Apex Pharma Distributors', 'Rohan Mehta', '+91-9811100011', 'DL-PH-2026-8891'),
    ('MedCore Supply Co.',       'Priya Nair',  '+91-9811100022', 'DL-PH-2026-9012');

INSERT INTO medicines (medicine_name, manufacturer, category, unit_price)
VALUES
    ('Amoxicillin 500mg', 'Cipla', 'Antibiotic', 10.00), -- medicine_id = 1
    ('Paracetamol 650mg', 'GSK',   'Analgesic',   5.00); -- medicine_id = 2

-- Batch 1 (med 1): Expired 5 days ago -> EXPIRED, locked
INSERT INTO inventory_batches (medicine_id, supplier_id, batch_code, manufacture_date, expiry_date, quantity_received, current_stock)
VALUES (1, 1, 'AMX-EXP-PAST', CURRENT_DATE - 180, CURRENT_DATE - 5, 30, 30);

-- Batch 2 (med 1): Exact 30-day boundary -> EXPIRING_SOON, locked
INSERT INTO inventory_batches (medicine_id, supplier_id, batch_code, manufacture_date, expiry_date, quantity_received, current_stock)
VALUES (1, 1, 'AMX-30D-LOCK', CURRENT_DATE - 150, CURRENT_DATE + 30, 25, 25);

-- Batch 3 (med 1): 31-day active boundary -> ACTIVE, unlocked (FIFO #1)
INSERT INTO inventory_batches (medicine_id, supplier_id, batch_code, manufacture_date, expiry_date, quantity_received, current_stock)
VALUES (1, 1, 'AMX-31D-OPEN', CURRENT_DATE - 120, CURRENT_DATE + 31, 20, 20);

-- Batch 4 (med 1): 180-day active batch -> ACTIVE, unlocked (FIFO #2)
INSERT INTO inventory_batches (medicine_id, supplier_id, batch_code, manufacture_date, expiry_date, quantity_received, current_stock)
VALUES (1, 2, 'AMX-180D-OPEN', CURRENT_DATE - 30, CURRENT_DATE + 180, 50, 50);

-- Batch 5 (med 2): 90-day active batch with 10 units -> ACTIVE, unlocked
INSERT INTO inventory_batches (medicine_id, supplier_id, batch_code, manufacture_date, expiry_date, quantity_received, current_stock)
VALUES (2, 2, 'PARA-90D-OPEN', CURRENT_DATE - 40, CURRENT_DATE + 90, 10, 10);

DO $$
DECLARE
    v_status     VARCHAR(20);
    v_locked     BOOLEAN;
    v_stock      INT;
    v_sale_id    INT;
    v_total      NUMERIC(12, 2);
    v_err_caught BOOLEAN;
BEGIN
    -- [TC-01] Boundary: 30 days to expiry -> EXPIRING_SOON and is_locked = TRUE
    SELECT expiry_status, is_locked
    INTO v_status, v_locked
    FROM inventory_batches
    WHERE batch_code = 'AMX-30D-LOCK';

    IF v_status <> 'EXPIRING_SOON' OR v_locked IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION 'TC-01 FAILED: expected EXPIRING_SOON & locked=true, got % & %', v_status, v_locked;
    END IF;
    RAISE NOTICE 'TC-01 PASSED: 30-day boundary auto-flagged EXPIRING_SOON and locked.';

    -- [TC-02] Boundary: 31 days to expiry -> ACTIVE and is_locked = FALSE
    SELECT expiry_status, is_locked
    INTO v_status, v_locked
    FROM inventory_batches
    WHERE batch_code = 'AMX-31D-OPEN';

    IF v_status <> 'ACTIVE' OR v_locked IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION 'TC-02 FAILED: expected ACTIVE & locked=false, got % & %', v_status, v_locked;
    END IF;
    RAISE NOTICE 'TC-02 PASSED: 31-day boundary remains ACTIVE and unlocked.';

    -- [TC-03] Invalid: Unlocking a batch expiring within <= 30 days must fail
    v_err_caught := FALSE;
    BEGIN
        SAVEPOINT sp_tc03;
        UPDATE inventory_batches
        SET is_locked = FALSE
        WHERE batch_code = 'AMX-30D-LOCK';
        ROLLBACK TO SAVEPOINT sp_tc03;
    EXCEPTION
        WHEN OTHERS THEN
            v_err_caught := TRUE;
            ROLLBACK TO SAVEPOINT sp_tc03;
    END;

    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'TC-03 FAILED: unlocking <=30-day batch should have raised an exception';
    END IF;
    RAISE NOTICE 'TC-03 PASSED: Unlock attempt on 30-day batch blocked by trigger.';

    -- [TC-04] Invalid: expiry_date <= manufacture_date must fail
    v_err_caught := FALSE;
    BEGIN
        SAVEPOINT sp_tc04;
        INSERT INTO inventory_batches (medicine_id, supplier_id, batch_code, manufacture_date, expiry_date, quantity_received, current_stock)
        VALUES (1, 1, 'AMX-BAD-DATE', CURRENT_DATE + 10, CURRENT_DATE + 5, 10, 10);
        ROLLBACK TO SAVEPOINT sp_tc04;
    EXCEPTION
        WHEN OTHERS THEN
            v_err_caught := TRUE;
            ROLLBACK TO SAVEPOINT sp_tc04;
    END;

    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'TC-04 FAILED: expiry_date <= manufacture_date should be rejected';
    END IF;
    RAISE NOTICE 'TC-04 PASSED: Invalid manufacture/expiry dates rejected.';

    -- [TC-05] Valid: FIFO sale of 35 units of medicine 1 spans AMX-31D-OPEN (20) + AMX-180D-OPEN (15)
    CALL sp_process_fifo_sale(
        'Aarav Gupta',
        '[{"medicine_id": 1, "quantity": 35}]'::jsonb,
        v_sale_id,
        v_total
    );

    IF v_sale_id IS NULL OR v_total <> 350.00 THEN
        RAISE EXCEPTION 'TC-05 FAILED: expected sale total 350.00, got sale_id=% total=%', v_sale_id, v_total;
    END IF;

    SELECT current_stock INTO v_stock FROM inventory_batches WHERE batch_code = 'AMX-31D-OPEN';
    IF v_stock <> 0 THEN
        RAISE EXCEPTION 'TC-05 FAILED: expected AMX-31D-OPEN stock 0, got %', v_stock;
    END IF;

    SELECT current_stock INTO v_stock FROM inventory_batches WHERE batch_code = 'AMX-180D-OPEN';
    IF v_stock <> 35 THEN
        RAISE EXCEPTION 'TC-05 FAILED: expected AMX-180D-OPEN stock 35, got %', v_stock;
    END IF;

    RAISE NOTICE 'TC-05 PASSED: FIFO sale #% committed (total: %) with exact batch depletion.', v_sale_id, v_total;

    -- [TC-06] Invalid: Requesting 25 units of medicine 2 (only 10 available) rolls back cleanly
    v_err_caught := FALSE;
    BEGIN
        SAVEPOINT sp_tc06;
        CALL sp_process_fifo_sale(
            'Vikram Rao',
            '[{"medicine_id": 2, "quantity": 25}]'::jsonb,
            v_sale_id,
            v_total
        );
        ROLLBACK TO SAVEPOINT sp_tc06;
    EXCEPTION
        WHEN OTHERS THEN
            v_err_caught := TRUE;
            ROLLBACK TO SAVEPOINT sp_tc06;
    END;

    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'TC-06 FAILED: oversell should have failed and rolled back';
    END IF;

    SELECT current_stock INTO v_stock FROM inventory_batches WHERE batch_code = 'PARA-90D-OPEN';
    IF v_stock <> 10 THEN
        RAISE EXCEPTION 'TC-06 FAILED: PARA-90D-OPEN stock should remain 10 after rollback, got %', v_stock;
    END IF;

    RAISE NOTICE 'TC-06 PASSED: Insufficient stock rolled back; PARA-90D-OPEN stock untouched at 10.';
END;
$$;
```

