CREATE TABLE IF NOT EXISTS sales_transactions (
    sale_id        SERIAL PRIMARY KEY,
    customer_name  VARCHAR(150)   NOT NULL,
    sale_date      TIMESTAMPTZ    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    total_amount   NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0)
);

CREATE TABLE IF NOT EXISTS sale_items (
    item_id        SERIAL PRIMARY KEY,
    sale_id        INT            NOT NULL REFERENCES sales_transactions(sale_id) ON DELETE CASCADE,
    batch_id       INT            NOT NULL REFERENCES inventory_batches(batch_id) ON DELETE RESTRICT,
    quantity_sold  INT            NOT NULL CHECK (quantity_sold > 0),
    unit_price     NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    subtotal       NUMERIC(12, 2) NOT NULL CHECK (subtotal >= 0)
);
