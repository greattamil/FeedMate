-- Andipatti Animal Feed System
-- Migration 0001: extensions, tenants, tenant configuration, financial years, document series

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- =====================================================================
-- tenants
-- =====================================================================
CREATE TABLE tenants (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    legal_name          varchar(200) NOT NULL,
    trade_name          varchar(200),
    gstin               varchar(15),
    fssai_license_no    varchar(100),
    phone               varchar(30),
    email               varchar(254),
    address_line1       varchar(250) NOT NULL,
    address_line2       varchar(250),
    city                varchar(100) NOT NULL,
    district            varchar(100),
    state_code          varchar(10) NOT NULL,
    postal_code         varchar(20),
    country_code        char(2) NOT NULL DEFAULT 'IN',
    currency_code       char(3) NOT NULL DEFAULT 'INR',
    timezone            varchar(64) NOT NULL DEFAULT 'Asia/Kolkata',
    invoice_prefix      varchar(20) NOT NULL DEFAULT 'INV',
    status              varchar(30) NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

-- UNIQUE(tenant_id, id) support pattern for composite tenant FKs.
ALTER TABLE tenants ADD CONSTRAINT uq_tenants_id UNIQUE (id);

-- =====================================================================
-- tenant_settings (typed columns for security/perf-critical config;
-- generic key/value for everything else)
-- =====================================================================
CREATE TABLE tenant_settings (
    tenant_id                       uuid PRIMARY KEY REFERENCES tenants(id),
    active_financial_year_id       uuid, -- FK added after financial_years created
    tare_default_max_pct           numeric(7,4) NOT NULL DEFAULT 5.0000,
    expiry_alert_thresholds_days   integer[] NOT NULL DEFAULT ARRAY[30,15,7,1],
    fifo_fefo_policy               varchar(10) NOT NULL DEFAULT 'FEFO' CHECK (fifo_fefo_policy IN ('FIFO','FEFO')),
    negative_stock_allowed         boolean NOT NULL DEFAULT false,
    offline_credit_safety_buffer   numeric(12,2) NOT NULL DEFAULT 0,
    collection_cycle_dates         integer[] NOT NULL DEFAULT ARRAY[9,24],
    reminder_days_before           integer NOT NULL DEFAULT 2,
    grace_period_days              integer NOT NULL DEFAULT 2,
    reminder_pause_dates           date[] NOT NULL DEFAULT ARRAY[]::date[],
    reminder_pause_reason          varchar(250),
    archive_retention_years        integer NOT NULL DEFAULT 7,
    extra_settings                 jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at                     timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- tenant_features (feature flags)
-- =====================================================================
CREATE TABLE tenant_features (
    tenant_id       uuid NOT NULL REFERENCES tenants(id),
    feature_code    varchar(80) NOT NULL,
    enabled         boolean NOT NULL DEFAULT false,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, feature_code)
);

-- =====================================================================
-- financial_years
-- =====================================================================
CREATE TABLE financial_years (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES tenants(id),
    label       varchar(20) NOT NULL, -- e.g. FY2026-27
    start_date  date NOT NULL,
    end_date    date NOT NULL,
    status      varchar(20) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CLOSED')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    closed_at   timestamptz,
    UNIQUE (tenant_id, label),
    UNIQUE (tenant_id, id),
    CHECK (end_date > start_date)
);

ALTER TABLE tenant_settings
    ADD CONSTRAINT fk_tenant_settings_fy
    FOREIGN KEY (tenant_id, active_financial_year_id)
    REFERENCES financial_years (tenant_id, id);

-- =====================================================================
-- document_series (per financial year, per document type)
-- =====================================================================
CREATE TABLE document_series (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               uuid NOT NULL REFERENCES tenants(id),
    financial_year_id       uuid NOT NULL,
    document_type           varchar(30) NOT NULL
                             CHECK (document_type IN ('INVOICE','CREDIT_NOTE','DEBIT_NOTE','PO','GRN','RECEIPT','RETURN','CONTRA')),
    prefix                  varchar(20) NOT NULL,
    next_number             bigint NOT NULL DEFAULT 1,
    padding                 integer NOT NULL DEFAULT 5,
    device_allocation_mode  varchar(20) NOT NULL DEFAULT 'SERVER' CHECK (device_allocation_mode IN ('SERVER','DEVICE_BLOCK')),
    active                  boolean NOT NULL DEFAULT true,
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, financial_year_id) REFERENCES financial_years (tenant_id, id),
    UNIQUE (tenant_id, financial_year_id, document_type, prefix)
);

CREATE INDEX idx_document_series_tenant ON document_series (tenant_id, document_type);
