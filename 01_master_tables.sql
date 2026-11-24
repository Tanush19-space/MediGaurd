CREATE TABLE IF NOT EXISTS suppliers (
    supplier_id     SERIAL PRIMARY KEY,
    supplier_name   VARCHAR(150) NOT NULL,
    contact_person  VARCHAR(120),
    phone           VARCHAR(25),
    license_number  VARCHAR(80)  NOT NULL UNIQUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS medicines (
    medicine_id    SERIAL PRIMARY KEY,
    medicine_name  VARCHAR(150)   NOT NULL,
    manufacturer   VARCHAR(150)   NOT NULL,
    category       VARCHAR(80)    NOT NULL,
    unit_price     NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    created_at     TIMESTAMPTZ    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_medicine_name_manufacturer UNIQUE (medicine_name, manufacturer)
);

CREATE TABLE IF NOT EXISTS inventory_batches (
    batch_id          SERIAL PRIMARY KEY,
    medicine_id       INT          NOT NULL REFERENCES medicines(medicine_id) ON DELETE RESTRICT,
    supplier_id       INT          NOT NULL REFERENCES suppliers(supplier_id) ON DELETE RESTRICT,
    batch_code        VARCHAR(60)  NOT NULL,
    manufacture_date  DATE         NOT NULL,
    expiry_date       DATE         NOT NULL,
    quantity_received INT          NOT NULL CHECK (quantity_received > 0),
    current_stock     INT          NOT NULL CHECK (current_stock >= 0 AND current_stock <= quantity_received),
    expiry_status     VARCHAR(20)  NOT NULL DEFAULT 'ACTIVE'
                          CHECK (expiry_status IN ('ACTIVE', 'EXPIRING_SOON', 'EXPIRED')),
    is_locked         BOOLEAN      NOT NULL DEFAULT FALSE,
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_valid_shelf_life CHECK (expiry_date > manufacture_date),
    CONSTRAINT uq_med_batch_code UNIQUE (medicine_id, batch_code)
);

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