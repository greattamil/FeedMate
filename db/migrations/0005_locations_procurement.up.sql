-- Migration 0005: inventory_locations, purchase_orders, purchase_order_lines, goods_receipts, goods_receipt_lines

CREATE TABLE inventory_locations (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenants(id),
    code            varchar(40) NOT NULL,
    name            varchar(150) NOT NULL,
    location_type   varchar(20) NOT NULL DEFAULT 'SHOP' CHECK (location_type IN ('SHOP','GODOWN','TRANSIT','QUARANTINE','RETURN')),
    active          boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code),
    UNIQUE (tenant_id, id)
);

CREATE TABLE purchase_orders (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    financial_year_id   uuid NOT NULL,
    po_number           varchar(60) NOT NULL,
    supplier_id         uuid NOT NULL,
    status              varchar(20) NOT NULL DEFAULT 'DRAFT'
                        CHECK (status IN ('DRAFT','APPROVED','SENT','PARTIALLY_RECEIVED','FULLY_RECEIVED','CLOSED','CANCELLED')),
    order_date          date NOT NULL DEFAULT CURRENT_DATE,
    expected_date       date,
    currency_code       char(3) NOT NULL DEFAULT 'INR',
    subtotal            numeric(12,2) NOT NULL DEFAULT 0,
    tax_total           numeric(12,2) NOT NULL DEFAULT 0,
    grand_total         numeric(12,2) NOT NULL DEFAULT 0,
    notes               varchar(500),
    approved_by_user_id uuid,
    approved_at         timestamptz,
    created_by_user_id  uuid,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, financial_year_id) REFERENCES financial_years (tenant_id, id),
    FOREIGN KEY (tenant_id, supplier_id) REFERENCES suppliers (tenant_id, id),
    UNIQUE (tenant_id, po_number),
    UNIQUE (tenant_id, id)
);
CREATE INDEX idx_po_tenant_status ON purchase_orders (tenant_id, status);

CREATE TABLE purchase_order_lines (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    purchase_order_id   uuid NOT NULL,
    line_no             integer NOT NULL,
    product_id          uuid NOT NULL,
    uom_id              uuid NOT NULL REFERENCES uoms(id),
    ordered_qty         numeric(12,3) NOT NULL CHECK (ordered_qty > 0),
    unit_cost           numeric(12,2) NOT NULL CHECK (unit_cost >= 0),
    discount_amount     numeric(12,2) NOT NULL DEFAULT 0,
    tax_profile_id      uuid,
    expected_tax        numeric(12,2) NOT NULL DEFAULT 0,
    line_total          numeric(12,2) NOT NULL DEFAULT 0,
    received_qty        numeric(12,3) NOT NULL DEFAULT 0,
    status              varchar(20) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','PARTIALLY_RECEIVED','FULLY_RECEIVED','CANCELLED')),
    FOREIGN KEY (tenant_id, purchase_order_id) REFERENCES purchase_orders (tenant_id, id),
    FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id),
    FOREIGN KEY (tenant_id, tax_profile_id) REFERENCES tax_profiles (tenant_id, id),
    UNIQUE (tenant_id, purchase_order_id, line_no)
);
CREATE INDEX idx_po_lines_po ON purchase_order_lines (tenant_id, purchase_order_id);

CREATE TABLE goods_receipts (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               uuid NOT NULL,
    financial_year_id       uuid NOT NULL,
    grn_number              varchar(60) NOT NULL,
    supplier_id             uuid NOT NULL,
    purchase_order_id       uuid,
    supplier_document_no    varchar(80),
    received_at             timestamptz NOT NULL DEFAULT now(),
    vehicle_no              varchar(30),
    receiver_user_id        uuid,
    status                  varchar(20) NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','POSTED','REVERSED')),
    gross_weight_kg         numeric(12,3),
    tare_weight_kg          numeric(12,3),
    net_weight_kg           numeric(12,3),
    tare_method             varchar(20) CHECK (tare_method IN ('COUNT_BASED','MEASURED','MANUAL') OR tare_method IS NULL),
    tare_threshold_pct      numeric(7,4),
    tare_override           boolean NOT NULL DEFAULT false,
    tare_override_reason    varchar(500),
    tare_override_by_user_id uuid,
    posted_at               timestamptz,
    created_at              timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, financial_year_id) REFERENCES financial_years (tenant_id, id),
    FOREIGN KEY (tenant_id, supplier_id) REFERENCES suppliers (tenant_id, id),
    FOREIGN KEY (tenant_id, purchase_order_id) REFERENCES purchase_orders (tenant_id, id),
    UNIQUE (tenant_id, grn_number),
    UNIQUE (tenant_id, id),
    CHECK (net_weight_kg IS NULL OR net_weight_kg >= 0),
    CHECK (
        gross_weight_kg IS NULL OR tare_weight_kg IS NULL OR net_weight_kg IS NULL
        OR net_weight_kg = gross_weight_kg - tare_weight_kg
    )
);
CREATE INDEX idx_grn_tenant_status ON goods_receipts (tenant_id, status);

CREATE TABLE goods_receipt_lines (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    goods_receipt_id    uuid NOT NULL,
    po_line_id          uuid,
    product_id          uuid NOT NULL,
    batch_id            uuid, -- FK added in migration 0006
    location_id         uuid NOT NULL,
    received_qty        numeric(12,3) NOT NULL CHECK (received_qty >= 0),
    received_uom_id     uuid NOT NULL REFERENCES uoms(id),
    gross_weight_kg     numeric(12,3),
    tare_weight_kg      numeric(12,3),
    net_weight_kg       numeric(12,3),
    unit_cost           numeric(12,2) NOT NULL CHECK (unit_cost >= 0),
    tax_profile_id      uuid,
    quality_status      varchar(20) NOT NULL DEFAULT 'ACCEPTED' CHECK (quality_status IN ('ACCEPTED','REJECTED','DAMAGED','QUARANTINE')),
    accepted_qty        numeric(12,3) NOT NULL DEFAULT 0,
    rejected_qty        numeric(12,3) NOT NULL DEFAULT 0,
    manufacture_date    date,
    expiry_date         date,
    FOREIGN KEY (tenant_id, goods_receipt_id) REFERENCES goods_receipts (tenant_id, id),
    FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id),
    FOREIGN KEY (tenant_id, location_id) REFERENCES inventory_locations (tenant_id, id),
    FOREIGN KEY (tenant_id, tax_profile_id) REFERENCES tax_profiles (tenant_id, id),
    UNIQUE (tenant_id, id)
);
CREATE INDEX idx_grn_lines_grn ON goods_receipt_lines (tenant_id, goods_receipt_id);
