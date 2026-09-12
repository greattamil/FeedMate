-- Migration 0004: customers, Khata credit profile, ledger, suppliers, supplier ledger

CREATE TABLE customers (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenants(id),
    customer_code   varchar(40) NOT NULL,
    name            varchar(200) NOT NULL,
    local_name      varchar(200),
    phone           varchar(30),
    whatsapp_phone  varchar(30),
    email           varchar(254),
    gstin           varchar(15),
    customer_type   varchar(30) NOT NULL DEFAULT 'WALK_IN' CHECK (customer_type IN ('WALK_IN','FARMER','WHOLESALE_DEALER','AAVIN_SUBCONTRACTOR','OTHER')),
    tier_id         uuid,
    status          varchar(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE','BLOCKED')),
    notes           varchar(500),
    whatsapp_opt_in boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, customer_code),
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, tier_id) REFERENCES customer_tiers (tenant_id, id)
);
CREATE INDEX idx_customers_tenant_phone ON customers (tenant_id, phone);
CREATE INDEX idx_customers_name_trgm ON customers USING gin (name gin_trgm_ops);

ALTER TABLE price_list_items
    ADD CONSTRAINT fk_price_list_items_customer
    FOREIGN KEY (tenant_id, customer_id) REFERENCES customers (tenant_id, id);

CREATE TABLE customer_addresses (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    customer_id     uuid NOT NULL,
    address_type    varchar(20) NOT NULL DEFAULT 'HOME',
    address_line1   varchar(250) NOT NULL,
    address_line2   varchar(250),
    city            varchar(100),
    state_code      varchar(10),
    postal_code     varchar(20),
    is_default      boolean NOT NULL DEFAULT false,
    FOREIGN KEY (tenant_id, customer_id) REFERENCES customers (tenant_id, id)
);

CREATE TABLE customer_credit_profiles (
    customer_id                uuid PRIMARY KEY,
    tenant_id                  uuid NOT NULL,
    credit_limit               numeric(12,2) NOT NULL DEFAULT 0,
    payment_terms_days         integer NOT NULL DEFAULT 0,
    grace_days                 integer NOT NULL DEFAULT 0,
    risk_status                varchar(20) NOT NULL DEFAULT 'NORMAL' CHECK (risk_status IN ('NORMAL','WATCH','BLOCKED')),
    offline_credit_limit       numeric(12,2) NOT NULL DEFAULT 0,
    override_required_above    numeric(12,2),
    effective_from             date NOT NULL DEFAULT CURRENT_DATE,
    updated_by_user_id         uuid,
    updated_at                 timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES customers (tenant_id, id)
);

-- Append-only ledger. Customer balance = SUM(debit) - SUM(credit) over posted rows.
CREATE TABLE customer_ledger_entries (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    customer_id         uuid NOT NULL,
    entry_date          timestamptz NOT NULL DEFAULT now(),
    document_type       varchar(30) NOT NULL CHECK (document_type IN ('INVOICE','RECEIPT','RETURN','CONTRA','ADJUSTMENT','OPENING_BALANCE')),
    document_id         uuid NOT NULL,
    debit               numeric(12,2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
    credit              numeric(12,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
    currency_code       char(3) NOT NULL DEFAULT 'INR',
    description         varchar(500),
    reversal_of_id      uuid,
    created_by_user_id  uuid,
    device_id           uuid,
    created_at          timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES customers (tenant_id, id),
    CHECK (NOT (debit > 0 AND credit > 0))
);
CREATE INDEX idx_customer_ledger_lookup ON customer_ledger_entries (tenant_id, customer_id, entry_date);
CREATE INDEX idx_customer_ledger_document ON customer_ledger_entries (tenant_id, document_type, document_id);

CREATE TABLE suppliers (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL REFERENCES tenants(id),
    supplier_code       varchar(40) NOT NULL,
    legal_name          varchar(200) NOT NULL,
    trade_name          varchar(200),
    gstin               varchar(15),
    phone               varchar(30),
    email               varchar(254),
    address_line1       varchar(250),
    city                varchar(100),
    state_code          varchar(10),
    payment_terms_days  integer NOT NULL DEFAULT 0,
    credit_limit        numeric(12,2),
    status              varchar(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, supplier_code),
    UNIQUE (tenant_id, id)
);
CREATE INDEX idx_suppliers_gstin ON suppliers (tenant_id, gstin);

CREATE TABLE supplier_contacts (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    supplier_id     uuid NOT NULL,
    name            varchar(150) NOT NULL,
    designation     varchar(100),
    phone           varchar(30),
    email           varchar(254),
    FOREIGN KEY (tenant_id, supplier_id) REFERENCES suppliers (tenant_id, id)
);

-- Sensitive banking data; access must be permission-restricted at the API layer.
CREATE TABLE supplier_bank_accounts (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    supplier_id         uuid NOT NULL,
    account_holder_name varchar(200) NOT NULL,
    bank_name           varchar(150),
    account_number_enc  varchar(500) NOT NULL, -- application-layer encrypted
    ifsc_code           varchar(20),
    upi_vpa             varchar(150),
    active              boolean NOT NULL DEFAULT true,
    FOREIGN KEY (tenant_id, supplier_id) REFERENCES suppliers (tenant_id, id)
);

CREATE TABLE supplier_ledger_entries (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    supplier_id         uuid NOT NULL,
    entry_date          timestamptz NOT NULL DEFAULT now(),
    document_type       varchar(30) NOT NULL CHECK (document_type IN ('GRN','PAYMENT','DEBIT_NOTE','CREDIT_NOTE','ADJUSTMENT','OPENING_BALANCE')),
    document_id         uuid NOT NULL,
    debit               numeric(12,2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
    credit              numeric(12,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
    description         varchar(500),
    reversal_of_id      uuid,
    created_by_user_id  uuid,
    created_at          timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, supplier_id) REFERENCES suppliers (tenant_id, id),
    CHECK (NOT (debit > 0 AND credit > 0))
);
CREATE INDEX idx_supplier_ledger_lookup ON supplier_ledger_entries (tenant_id, supplier_id, entry_date);
