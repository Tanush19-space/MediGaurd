-- sql/01_master_tables.sql
CREATE TABLE suppliers (
    supplier_id     SERIAL PRIMARY KEY,
    supplier_name   VARCHAR(150) NOT NULL,
    contact_person  VARCHAR(120),
    phone           VARCHAR(25),
    license_number  VARCHAR(80)  NOT NULL UNIQUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE medicines (
    medicine_id    SERIAL PRIMARY KEY,
    medicine_name  VARCHAR(150)   NOT NULL,
    manufacturer   VARCHAR(150)   NOT NULL,
    category       VARCHAR(80)    NOT NULL,
    unit_price     NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    created_at     TIMESTAMPTZ    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_medicine_name_manufacturer UNIQUE (medicine_name, manufacturer)
);-- sql/02_inventory_batches.sql
CREATE TABLE inventory_batches (
    batch_id          SERIAL PRIMARY KEY,
    medicine_id       INT          NOT NULL REFERENCES medicines(medicine_id) ON DELETE 
RESTRICT,
    supplier_id       INT          NOT NULL REFERENCES suppliers(supplier_id) ON DELETE 
RESTRICT,
    batch_code        VARCHAR(60)  NOT NULL,
    manufacture_date  DATE         NOT NULL,
    expiry_date       DATE         NOT NULL,
    quantity_received INT          NOT NULL CHECK (quantity_received > 0),
    current_stock     INT          NOT NULL CHECK (current_stock >= 0 AND current_stock <= 
quantity_received),
    expiry_status     VARCHAR(20)  NOT NULL DEFAULT 'ACTIVE'
                          CHECK (expiry_status IN ('ACTIVE', 'EXPIRING_SOON', 'EXPIRED')),
    is_locked         BOOLEAN      NOT NULL DEFAULT FALSE,
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_valid_shelf_life CHECK (expiry_date > manufacture_date),
    CONSTRAINT uq_med_batch_code UNIQUE (medicine_id, batch_code)
);
CREATE INDEX idx_batches_fifo_lookup
    ON inventory_batches (medicine_id, expiry_date ASC, batch_id ASC)
    WHERE current_stock > 0 AND is_locked = FALSE AND expiry_status <> 'EXPIRED';