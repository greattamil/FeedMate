-- Migration 0007: sales_invoices, sales_invoice_lines, invoice_tax_lines,
-- invoice_batch_allocations, invoice_tenders, sales_returns, sales_return_lines

CREATE TABLE sales_invoices (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               uuid NOT NULL,
    financial_year_id       uuid NOT NULL,
    invoice_number          varchar(60) NOT NULL,
    invoice_date            timestamptz NOT NULL DEFAULT now(),
    customer_id             uuid,
    customer_name_snapshot  varchar(250),
    customer_gstin_snapshot varchar(15),
    place_of_supply         varchar(10),
    subtotal                numeric(12,2) NOT NULL DEFAULT 0,
    discount_total          numeric(12,2) NOT NULL DEFAULT 0,
    taxable_total           numeric(12,2) NOT NULL DEFAULT 0,
    tax_total               numeric(12,2) NOT NULL DEFAULT 0,
    rounding_amount         numeric(12,2) NOT NULL DEFAULT 0,
    grand_total             numeric(12,2) NOT NULL DEFAULT 0,
    payment_status          varchar(20) NOT NULL DEFAULT 'UNPAID'
                            CHECK (payment_status IN ('UNPAID','PARTIAL','PAID','CREDIT','REFUNDED')),
    status                  varchar(20) NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','FINALIZED','CANCELLED','RETURNED')),
    cancel_reason           varchar(500),
    source                  varchar(10) NOT NULL DEFAULT 'ONLINE' CHECK (source IN ('ONLINE','OFFLINE')),
    client_transaction_id   uuid,
    device_id               uuid,
    cashier_user_id         uuid,
    correlation_id          uuid NOT NULL DEFAULT gen_random_uuid(),
    created_at              timestamptz NOT NULL DEFAULT now(),
    finalized_at            timestamptz,
    cancelled_at            timestamptz,
    FOREIGN KEY (tenant_id, financial_year_id) REFERENCES financial_years (tenant_id, id),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES customers (tenant_id, id),
    UNIQUE (tenant_id, invoice_number),
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, device_id, client_transaction_id)
);
CREATE INDEX idx_invoices_tenant_date ON sales_invoices (tenant_id, invoice_date);
CREATE INDEX idx_invoices_customer_date ON sales_invoices (tenant_id, customer_id, invoice_date);
CREATE INDEX idx_invoices_status ON sales_invoices (tenant_id, status);

CREATE TABLE sales_invoice_lines (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    invoice_id          uuid NOT NULL,
    line_no             integer NOT NULL,
    product_id          uuid NOT NULL,
    product_name_snapshot varchar(250) NOT NULL,
    sku_snapshot        varchar(80) NOT NULL,
    hsn_snapshot        varchar(20),
    uom_id              uuid NOT NULL REFERENCES uoms(id),
    uom_code_snapshot   varchar(20) NOT NULL,
    quantity            numeric(12,3) NOT NULL CHECK (quantity > 0),
    weight_source       varchar(10) CHECK (weight_source IN ('SCALE','MANUAL') OR weight_source IS NULL),
    weight_override_reason varchar(250),
    unit_price          numeric(12,2) NOT NULL CHECK (unit_price >= 0),
    discount_amount     numeric(12,2) NOT NULL DEFAULT 0,
    taxable_value       numeric(12,2) NOT NULL DEFAULT 0,
    tax_profile_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
    tax_total           numeric(12,2) NOT NULL DEFAULT 0,
    line_total          numeric(12,2) NOT NULL DEFAULT 0,
    FOREIGN KEY (tenant_id, invoice_id) REFERENCES sales_invoices (tenant_id, id),
    FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id),
    UNIQUE (tenant_id, invoice_id, line_no),
    UNIQUE (tenant_id, id)
);
CREATE INDEX idx_invoice_lines_invoice ON sales_invoice_lines (tenant_id, invoice_id);

CREATE TABLE invoice_tax_lines (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    invoice_id          uuid NOT NULL,
    invoice_line_id     uuid,
    tax_type            varchar(10) NOT NULL CHECK (tax_type IN ('CGST','SGST','IGST','CESS')),
    rate                numeric(7,4) NOT NULL,
    taxable_value       numeric(12,2) NOT NULL,
    tax_amount          numeric(12,2) NOT NULL,
    jurisdiction_state  varchar(10),
    FOREIGN KEY (tenant_id, invoice_id) REFERENCES sales_invoices (tenant_id, id),
    FOREIGN KEY (tenant_id, invoice_line_id) REFERENCES sales_invoice_lines (tenant_id, id)
);
CREATE INDEX idx_invoice_tax_lines_invoice ON invoice_tax_lines (tenant_id, invoice_id);

CREATE TABLE invoice_batch_allocations (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    invoice_line_id     uuid NOT NULL,
    batch_id            uuid NOT NULL,
    quantity            numeric(12,3) NOT NULL CHECK (quantity > 0),
    uom_id              uuid NOT NULL REFERENCES uoms(id),
    unit_cost           numeric(12,2) NOT NULL,
    cost_value          numeric(12,2) NOT NULL,
    FOREIGN KEY (tenant_id, invoice_line_id) REFERENCES sales_invoice_lines (tenant_id, id),
    FOREIGN KEY (tenant_id, batch_id) REFERENCES batches (tenant_id, id)
);
CREATE INDEX idx_invoice_batch_alloc_line ON invoice_batch_allocations (tenant_id, invoice_line_id);

-- Multi-tender: sum(amount) must equal invoice.grand_total, enforced by application transaction logic.
CREATE TABLE invoice_tenders (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    invoice_id      uuid NOT NULL,
    tender_method   varchar(20) NOT NULL CHECK (tender_method IN ('CASH','UPI','BANK','CREDIT','OTHER')),
    amount          numeric(12,2) NOT NULL CHECK (amount > 0),
    payment_id      uuid, -- FK added in migration 0008
    reference        varchar(150),
    created_at      timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, invoice_id) REFERENCES sales_invoices (tenant_id, id)
);
CREATE INDEX idx_invoice_tenders_invoice ON invoice_tenders (tenant_id, invoice_id);

CREATE TABLE sales_returns (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    return_number       varchar(60) NOT NULL,
    original_invoice_id uuid,
    customer_id         uuid,
    return_date         timestamptz NOT NULL DEFAULT now(),
    reason              varchar(500),
    status              varchar(20) NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','POSTED','CANCELLED')),
    subtotal            numeric(12,2) NOT NULL DEFAULT 0,
    tax_total           numeric(12,2) NOT NULL DEFAULT 0,
    total               numeric(12,2) NOT NULL DEFAULT 0,
    refund_status       varchar(20) NOT NULL DEFAULT 'PENDING' CHECK (refund_status IN ('PENDING','PARTIAL','COMPLETED','NOT_APPLICABLE')),
    created_by_user_id  uuid,
    created_at          timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, original_invoice_id) REFERENCES sales_invoices (tenant_id, id),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES customers (tenant_id, id),
    UNIQUE (tenant_id, return_number),
    UNIQUE (tenant_id, id)
);

CREATE TABLE sales_return_lines (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    sales_return_id     uuid NOT NULL,
    original_line_id    uuid,
    product_id          uuid NOT NULL,
    batch_id            uuid,
    quantity            numeric(12,3) NOT NULL CHECK (quantity > 0),
    uom_id              uuid NOT NULL REFERENCES uoms(id),
    condition_status    varchar(20) NOT NULL DEFAULT 'SELLABLE' CHECK (condition_status IN ('SELLABLE','DAMAGED','EXPIRED','QUARANTINE','OTHER')),
    restock_location_id uuid,
    refund_amount       numeric(12,2) NOT NULL DEFAULT 0,
    FOREIGN KEY (tenant_id, sales_return_id) REFERENCES sales_returns (tenant_id, id),
    FOREIGN KEY (tenant_id, original_line_id) REFERENCES sales_invoice_lines (tenant_id, id),
    FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id),
    FOREIGN KEY (tenant_id, batch_id) REFERENCES batches (tenant_id, id),
    FOREIGN KEY (tenant_id, restock_location_id) REFERENCES inventory_locations (tenant_id, id),
    UNIQUE (tenant_id, id)
);
