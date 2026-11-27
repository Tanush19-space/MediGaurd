CREATE OR REPLACE FUNCTION fn_evaluate_batch_expiry_and_lock()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_days_to_expiry INT;
BEGIN
    IF NEW.manufacture_date IS NULL OR NEW.expiry_date IS NULL THEN
        RAISE EXCEPTION 'manufacture_date and expiry_date cannot be NULL for batch %', NEW.batch_code;
    END IF;

    IF NEW.expiry_date <= NEW.manufacture_date THEN
        RAISE EXCEPTION 'Invalid shelf life for batch %: expiry_date (%) must be strictly after manufacture_date (%)',
            NEW.batch_code, NEW.expiry_date, NEW.manufacture_date;
    END IF;

    IF NEW.quantity_received IS NULL OR NEW.quantity_received <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity_received (%) for batch %: must be greater than 0',
            NEW.quantity_received, NEW.batch_code;
    END IF;

    IF NEW.current_stock IS NULL OR NEW.current_stock < 0 OR NEW.current_stock > NEW.quantity_received THEN
        RAISE EXCEPTION 'Invalid current_stock (%) for batch %: must be between 0 and quantity_received (%)',
            NEW.current_stock, NEW.batch_code, NEW.quantity_received;
    END IF;

    v_days_to_expiry := NEW.expiry_date - CURRENT_DATE;

    IF TG_OP = 'UPDATE'
       AND OLD.is_locked
       AND NOT NEW.is_locked
       AND v_days_to_expiry <= 30 THEN
        RAISE EXCEPTION 'Lock violation on batch %: cannot unlock stock expiring in % days (<= 30-day rule)',
            NEW.batch_code, v_days_to_expiry;
    END IF;

    IF v_days_to_expiry < 0 THEN
        NEW.expiry_status := 'EXPIRED';
        NEW.is_locked := TRUE;
    ELSIF v_days_to_expiry <= 30 THEN
        NEW.expiry_status := 'EXPIRING_SOON';
        NEW.is_locked := TRUE;
    ELSE
        NEW.expiry_status := 'ACTIVE';

        IF TG_OP = 'UPDATE'
           AND OLD.is_locked
           AND NEW.is_locked THEN
            NEW.is_locked := FALSE;
        END IF;
    END IF;

    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_inventory_batches_expiry_guard ON inventory_batches;

CREATE TRIGGER trg_inventory_batches_expiry_guard
BEFORE INSERT OR UPDATE ON inventory_batches
FOR EACH ROW
EXECUTE FUNCTION fn_evaluate_batch_expiry_and_lock();

CREATE OR REPLACE PROCEDURE sp_refresh_all_batch_expiry_statuses()
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
    UPDATE inventory_batches
    SET updated_at = CURRENT_TIMESTAMP;
END;
$$;
