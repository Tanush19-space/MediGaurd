CREATE INDEX IF NOT EXISTS idx_batches_fifo_lookup
    ON inventory_batches (medicine_id, expiry_date ASC, batch_id ASC)
    WHERE current_stock > 0 AND is_locked = FALSE AND expiry_status = 'ACTIVE';

CREATE INDEX IF NOT EXISTS idx_batches_expiry_stock
    ON inventory_batches (expiry_date ASC, current_stock)
    WHERE current_stock > 0;

CREATE INDEX IF NOT EXISTS idx_batches_sellable_fifo_cover
    ON inventory_batches (medicine_id, expiry_date ASC)
    INCLUDE (batch_id, current_stock)
    WHERE current_stock > 0 AND is_locked = FALSE AND expiry_status = 'ACTIVE';

CREATE INDEX IF NOT EXISTS idx_sales_transactions_sale_date
    ON sales_transactions (sale_date DESC, sale_id);

CREATE INDEX IF NOT EXISTS idx_sale_items_sale_batch
    ON sale_items (sale_id, batch_id)
    INCLUDE (quantity_sold, unit_price, subtotal);

ANALYZE inventory_batches;
ANALYZE sales_transactions;
ANALYZE sale_items;

-- Report A: 30-day expiry and lock audit with the inventory value at risk.
SELECT
    ib.batch_id,
    ib.batch_code,
    m.medicine_name,
    m.manufacturer,
    m.category,
    s.supplier_name,
    ib.manufacture_date,
    ib.expiry_date,
    ib.expiry_date - CURRENT_DATE AS days_to_expiry,
    ib.expiry_status,
    ib.is_locked,
    ib.current_stock,
    m.unit_price,
    ROUND(ib.current_stock * m.unit_price, 2) AS stock_value_at_risk
FROM inventory_batches ib
JOIN medicines m ON m.medicine_id = ib.medicine_id
JOIN suppliers s ON s.supplier_id = ib.supplier_id
WHERE ib.current_stock > 0
  AND (ib.expiry_date <= CURRENT_DATE + 30 OR ib.is_locked)
ORDER BY ib.expiry_date, stock_value_at_risk DESC;

-- Report B: sellable inventory, excluding batches at or inside the safety lock.
SELECT
    m.medicine_id,
    m.medicine_name,
    m.category,
    m.unit_price,
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
ORDER BY m.medicine_name;

-- Report C: recent sales with batch and supplier traceability.
SELECT
    st.sale_id,
    st.sale_date::DATE AS sale_day,
    st.customer_name,
    m.medicine_name,
    ib.batch_code,
    ib.expiry_date,
    s.supplier_name,
    si.quantity_sold,
    si.unit_price,
    si.subtotal,
    st.total_amount AS transaction_total
FROM sales_transactions st
JOIN sale_items si ON si.sale_id = st.sale_id
JOIN inventory_batches ib ON ib.batch_id = si.batch_id
JOIN medicines m ON m.medicine_id = ib.medicine_id
JOIN suppliers s ON s.supplier_id = ib.supplier_id
WHERE st.sale_date >= CURRENT_DATE - 30
ORDER BY st.sale_date DESC, st.sale_id DESC, si.item_id;

-- Compare a sequential baseline with the normal planner. Small datasets may
-- still favor sequential scans even after indexes are available.
BEGIN;
SET LOCAL enable_indexscan = OFF;
SET LOCAL enable_indexonlyscan = OFF;
SET LOCAL enable_bitmapscan = OFF;
EXPLAIN (ANALYZE, BUFFERS)
SELECT batch_id, batch_code, expiry_date, current_stock
FROM inventory_batches
WHERE current_stock > 0
  AND (expiry_date <= CURRENT_DATE + 30 OR is_locked)
ORDER BY expiry_date;

SET LOCAL enable_indexscan = ON;
SET LOCAL enable_indexonlyscan = ON;
SET LOCAL enable_bitmapscan = ON;
EXPLAIN (ANALYZE, BUFFERS)
SELECT batch_id, batch_code, expiry_date, current_stock
FROM inventory_batches
WHERE current_stock > 0
  AND (expiry_date <= CURRENT_DATE + 30 OR is_locked)
ORDER BY expiry_date;
ROLLBACK;
