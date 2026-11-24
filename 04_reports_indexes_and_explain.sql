**File Path:** `sql/04_reports_indexes_and_explain.sql`

```sql
-- ============================================================================
-- MEMBER 4: REPORTING QUERIES, INDEXES & EXECUTION PLAN VERIFICATION
-- File: sql/04_reports_indexes_and_explain.sql
-- Target DBMS: PostgreSQL
-- ============================================================================

-- 1. Indexes supporting expiry audits, FIFO stock lookups, and sales reporting
`
CREATE INDEX IF NOT EXISTS idx_batches_fifo_lookup
    ON inventory_batches (medicine_id, expiry_date ASC, batch_id ASC)
    WHERE current_stock > 0 AND is_locked = FALSE AND expiry_status <> 'EXPIRED';

CREATE INDEX IF NOT EXISTS idx_batches_expiry_stock
    ON inventory_batches (expiry_date ASC, current_stock)
    WHERE current_stock > 0;

CREATE INDEX IF NOT EXISTS idx_batches_sellable_fifo_cover
    ON inventory_batches (medicine_id, expiry_date ASC)
    INCLUDE (current_stock)
    WHERE current_stock > 0 AND is_locked = FALSE AND expiry_status = 'ACTIVE';

CREATE INDEX IF NOT EXISTS idx_sales_transactions_sale_date
    ON sales_transactions (sale_date DESC, sale_id);

CREATE INDEX IF NOT EXISTS idx_sale_items_sale_batch
    ON sale_items (sale_id, batch_id)
    INCLUDE (quantity_sold, unit_price, subtotal);

ANALYZE inventory_batches;
ANALYZE sales_transactions;
ANALYZE sale_items;

-- 2. Report A: Batch Expiry & Lock Audit Report
SELECT
    ib.batch_id,
    ib.batch_code,
    m.medicine_name,
    m.manufacturer,
    m.category,
    s.supplier_name,
    ib.manufacture_date,
    ib.expiry_date,
    (ib.expiry_date - CURRENT_DATE) AS days_to_expiry,
    ib.expiry_status,
    ib.is_locked,
    ib.current_stock,
    m.unit_price,
    ROUND(ib.current_stock * m.unit_price, 2) AS stock_value_at_risk
FROM inventory_batches ib
JOIN medicines m ON m.medicine_id = ib.medicine_id
JOIN suppliers s ON s.supplier_id = ib.supplier_id
WHERE ib.current_stock > 0
  AND (
      ib.expiry_date <= CURRENT_DATE + INTERVAL '30 days'
      OR ib.is_locked = TRUE
  )
ORDER BY ib.expiry_date ASC, stock_value_at_risk DESC;

-- 3. Report B: Sellable FIFO Stock Summary by Medicine
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
   AND (ib.expiry_date - CURRENT_DATE) > 30
GROUP BY m.medicine_id, m.medicine_name, m.category, m.unit_price
ORDER BY m.medicine_name ASC;

-- 4. Report C: Recent Sales & Batch Traceability Report
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
WHERE st.sale_date >= CURRENT_DATE - INTERVAL '30 days'
ORDER BY st.sale_date DESC, st.sale_id DESC, si.item_id ASC;

-- 5. Execution Plan Check for Report A
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    ib.batch_id,
    ib.batch_code,
    m.medicine_name,
    s.supplier_name,
    ib.expiry_date,
    ib.current_stock,
    ROUND(ib.current_stock * m.unit_price, 2) AS stock_value_at_risk
FROM inventory_batches ib
JOIN medicines m ON m.medicine_id = ib.medicine_id
JOIN suppliers s ON s.supplier_id = ib.supplier_id
WHERE ib.current_stock > 0
  AND (
      ib.expiry_date <= CURRENT_DATE + INTERVAL '30 days'
      OR ib.is_locked = TRUE
  )
ORDER BY ib.expiry_date ASC, stock_value_at_risk DESC;