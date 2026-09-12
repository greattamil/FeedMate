-- Migration 0006: batches, stock_movements (authoritative ledger), stock_balances (projection),
-- stock_counts, stock_count_lines, stock_adjustments

CREATE TABLE batches (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    product_id      uuid NOT NULL,
    supplier_id     uuid,
    grn_line_id     uuid,
    batch_code      varchar(80) NOT NULL,
    manufacture_date date,
    expiry_date     date,
    received_date   date NOT NULL DEFAULT CURRENT_DATE,
    received_qty    numeric(12,3) NOT NULL CHECK (received_qty >= 0),
    available_qty   numeric(12,3) NOT NULL DEFAULT 0,
    received_uom_id uuid NOT NULL REFERENCES uoms(id),
    unit_cost       numeric(12,2) NOT NULL DEFAULT 0,
    location_id     uuid NOT NULL,
    quality_status  varchar(20) NOT NULL DEFAULT 'ACCEPTED' CHECK (quality_status IN ('ACCEPTED','REJECTED','DAMAGED','QUARANTINE')),
    status          varchar(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','NEAR_EXPIRY','EXPIRED','QUARANTINED','DEPLETED','CLOSED')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id),
    FOREIGN KEY (tenant_id, supplier_id) REFERENCES suppliers (tenant_id, id),
    FOREIGN KEY (tenant_id, location_id) REFERENCES inventory_locations (tenant_id, id),
    UNIQUE (tenant_id, product_id, batch_code, received_date),
    UNIQUE (tenant_id, id)
);
CREATE INDEX idx_batches_expiry ON batches (tenant_id, status, expiry_date);
CREATE INDEX idx_batches_product_status ON batches (tenant_id, product_id, status, expiry_date);

ALTER TABLE goods_receipt_lines
    ADD CONSTRAINT fk_grn_lines_batch
    FOREIGN KEY (tenant_id, batch_id) REFERENCES batches (tenant_id, id);

ALTER TABLE batches
    ADD CONSTRAINT fk_batches_grn_line
    FOREIGN KEY (tenant_id, grn_line_id) REFERENCES goods_receipt_lines (tenant_id, id);

-- =====================================================================
-- stock_movements — the authoritative, append-only inventory ledger.
-- Every physical/financial stock change is represented here; stock_balances
-- is a reconcilable projection only.
-- =====================================================================
CREATE TABLE stock_movements (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    movement_time       timestamptz NOT NULL DEFAULT now(),
    product_id          uuid NOT NULL,
    batch_id            uuid,
    location_id         uuid NOT NULL,
    uom_id              uuid NOT NULL REFERENCES uoms(id),
    quantity            numeric(12,3) NOT NULL CHECK (quantity >= 0), -- unsigned magnitude
    signed_quantity     numeric(12,3) NOT NULL, -- positive receipt / negative issue
    movement_type       varchar(30) NOT NULL CHECK (movement_type IN (
                            'OPENING','PURCHASE_GRN','SALE','SALE_RETURN','PURCHASE_RETURN',
                            'ADJUSTMENT','DAMAGE','EXPIRY','TRANSFER_OUT','TRANSFER_IN',
                            'CONVERSION','REPACK','CONTRA_RECEIPT','MANUAL_CORRECTION')),
    source_type         varchar(40) NOT NULL, -- INVOICE/GRN/RETURN/CONTRA/STOCK_COUNT/etc.
    source_id           uuid,
    source_line_id      uuid,
    unit_cost           numeric(12,2),
    reason_code         varchar(50),
    device_id           uuid,
    created_by_user_id  uuid,
    created_at          timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id),
    FOREIGN KEY (tenant_id, batch_id) REFERENCES batches (tenant_id, id),
    FOREIGN KEY (tenant_id, location_id) REFERENCES inventory_locations (tenant_id, id)
);
CREATE INDEX idx_stock_movements_product_time ON stock_movements (tenant_id, product_id, movement_time);
CREATE INDEX idx_stock_movements_batch_time ON stock_movements (tenant_id, batch_id, movement_time);
CREATE INDEX idx_stock_movements_source ON stock_movements (tenant_id, source_type, source_id);
ALTER TABLE stock_movements ADD CONSTRAINT uq_stock_movements_id UNIQUE (tenant_id, id);

-- Projection/cache. Reconciled from stock_movements; never authoritative on its own.
CREATE TABLE stock_balances (
    tenant_id       uuid NOT NULL,
    product_id      uuid NOT NULL,
    batch_id        uuid NOT NULL,
    location_id     uuid NOT NULL,
    uom_id          uuid NOT NULL REFERENCES uoms(id),
    on_hand_qty     numeric(12,3) NOT NULL DEFAULT 0,
    reserved_qty    numeric(12,3) NOT NULL DEFAULT 0,
    available_qty   numeric(12,3) GENERATED ALWAYS AS (on_hand_qty - reserved_qty) STORED,
    damaged_qty     numeric(12,3) NOT NULL DEFAULT 0,
    quarantine_qty  numeric(12,3) NOT NULL DEFAULT 0,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, product_id, batch_id, location_id, uom_id),
    FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id),
    FOREIGN KEY (tenant_id, batch_id) REFERENCES batches (tenant_id, id),
    FOREIGN KEY (tenant_id, location_id) REFERENCES inventory_locations (tenant_id, id)
);

CREATE TABLE stock_counts (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    location_id     uuid NOT NULL,
    count_mode      varchar(20) NOT NULL DEFAULT 'CYCLE' CHECK (count_mode IN ('FULL','CYCLE')),
    started_at      timestamptz NOT NULL DEFAULT now(),
    completed_at    timestamptz,
    status          varchar(20) NOT NULL DEFAULT 'IN_PROGRESS' CHECK (status IN ('IN_PROGRESS','PENDING_APPROVAL','POSTED','CANCELLED')),
    counted_by_user_id  uuid,
    approved_by_user_id uuid,
    FOREIGN KEY (tenant_id, location_id) REFERENCES inventory_locations (tenant_id, id),
    UNIQUE (tenant_id, id)
);

CREATE TABLE stock_count_lines (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    stock_count_id      uuid NOT NULL,
    product_id          uuid NOT NULL,
    batch_id            uuid,
    expected_qty        numeric(12,3) NOT NULL DEFAULT 0,
    counted_qty         numeric(12,3) NOT NULL DEFAULT 0,
    variance_qty        numeric(12,3) GENERATED ALWAYS AS (counted_qty - expected_qty) STORED,
    variance_value      numeric(12,2),
    reason              varchar(250),
    requires_approval   boolean NOT NULL DEFAULT false,
    FOREIGN KEY (tenant_id, stock_count_id) REFERENCES stock_counts (tenant_id, id),
    FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id),
    FOREIGN KEY (tenant_id, batch_id) REFERENCES batches (tenant_id, id)
);

CREATE TABLE stock_adjustments (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    product_id          uuid NOT NULL,
    batch_id            uuid,
    location_id         uuid NOT NULL,
    adjustment_type     varchar(20) NOT NULL CHECK (adjustment_type IN ('STOCK_COUNT','DAMAGE','EXPIRY','MANUAL_CORRECTION')),
    quantity_delta      numeric(12,3) NOT NULL,
    reason              varchar(500) NOT NULL,
    source_stock_count_id uuid,
    stock_movement_id   uuid,
    requested_by_user_id uuid,
    approved_by_user_id  uuid,
    created_at          timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id),
    FOREIGN KEY (tenant_id, batch_id) REFERENCES batches (tenant_id, id),
    FOREIGN KEY (tenant_id, location_id) REFERENCES inventory_locations (tenant_id, id),
    FOREIGN KEY (tenant_id, stock_movement_id) REFERENCES stock_movements (tenant_id, id)
);
