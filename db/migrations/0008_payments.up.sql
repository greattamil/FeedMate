-- Migration 0008: payment_intents, payments, payment_allocations, payment_webhook_events, refunds

CREATE TABLE payment_intents (
    id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                   uuid NOT NULL,
    invoice_id                  uuid,
    customer_id                 uuid,
    provider                    varchar(40) NOT NULL,
    provider_order_reference    varchar(150),
    amount                      numeric(12,2) NOT NULL CHECK (amount > 0),
    currency_code               char(3) NOT NULL DEFAULT 'INR',
    status                      varchar(20) NOT NULL DEFAULT 'CREATED'
                                CHECK (status IN ('CREATED','PENDING','SUCCESS','FAILED','EXPIRED','CANCELLED')),
    expires_at                  timestamptz,
    idempotency_key             varchar(150) NOT NULL,
    created_at                  timestamptz NOT NULL DEFAULT now(),
    updated_at                  timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, invoice_id) REFERENCES sales_invoices (tenant_id, id),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES customers (tenant_id, id),
    UNIQUE (tenant_id, idempotency_key),
    UNIQUE (tenant_id, id)
);
CREATE INDEX idx_payment_intents_status ON payment_intents (tenant_id, status);

CREATE TABLE payments (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    payment_intent_id   uuid,
    provider            varchar(40) NOT NULL,
    provider_payment_id varchar(150),
    method              varchar(20) NOT NULL CHECK (method IN ('CASH','UPI','BANK','CREDIT','OTHER')),
    amount              numeric(12,2) NOT NULL CHECK (amount > 0),
    status              varchar(20) NOT NULL DEFAULT 'CREATED'
                        CHECK (status IN ('CREATED','PENDING','SUCCESS','FAILED','EXPIRED','REFUNDED','REVERSED','UNKNOWN')),
    settlement_status   varchar(20) NOT NULL DEFAULT 'PENDING' CHECK (settlement_status IN ('PENDING','SETTLED','MISMATCHED')),
    received_at         timestamptz,
    raw_reference       jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, payment_intent_id) REFERENCES payment_intents (tenant_id, id),
    UNIQUE (tenant_id, id),
    UNIQUE (provider, provider_payment_id)
);
CREATE INDEX idx_payments_status ON payments (tenant_id, status, created_at);

ALTER TABLE invoice_tenders
    ADD CONSTRAINT fk_invoice_tenders_payment
    FOREIGN KEY (tenant_id, payment_id) REFERENCES payments (tenant_id, id);

CREATE TABLE payment_allocations (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    payment_id          uuid NOT NULL,
    invoice_id          uuid,
    customer_ledger_entry_id uuid,
    allocated_amount    numeric(12,2) NOT NULL CHECK (allocated_amount > 0),
    created_at          timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, payment_id) REFERENCES payments (tenant_id, id),
    FOREIGN KEY (tenant_id, invoice_id) REFERENCES sales_invoices (tenant_id, id)
);
CREATE INDEX idx_payment_allocations_payment ON payment_allocations (tenant_id, payment_id);

-- tenant_id nullable until the webhook is safely resolved to a tenant context.
CREATE TABLE payment_webhook_events (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid,
    provider            varchar(40) NOT NULL,
    event_id            varchar(200) NOT NULL,
    signature_verified  boolean NOT NULL DEFAULT false,
    received_at         timestamptz NOT NULL DEFAULT now(),
    event_type          varchar(60) NOT NULL,
    payload_hash        varchar(128) NOT NULL,
    payload             jsonb NOT NULL,
    processing_status   varchar(20) NOT NULL DEFAULT 'RECEIVED'
                        CHECK (processing_status IN ('RECEIVED','PROCESSED','IGNORED','ERROR')),
    processed_at        timestamptz,
    error_code          varchar(60),
    UNIQUE (provider, event_id)
);
CREATE INDEX idx_payment_webhook_status ON payment_webhook_events (processing_status, received_at);

CREATE TABLE refunds (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    payment_id          uuid NOT NULL,
    return_id           uuid,
    provider_refund_id  varchar(150),
    amount              numeric(12,2) NOT NULL CHECK (amount > 0),
    status              varchar(20) NOT NULL DEFAULT 'REQUESTED'
                        CHECK (status IN ('REQUESTED','PROCESSING','COMPLETED','FAILED')),
    reason              varchar(500),
    requested_by_user_id uuid,
    approved_by_user_id  uuid,
    created_at          timestamptz NOT NULL DEFAULT now(),
    completed_at        timestamptz,
    FOREIGN KEY (tenant_id, payment_id) REFERENCES payments (tenant_id, id),
    FOREIGN KEY (tenant_id, return_id) REFERENCES sales_returns (tenant_id, id),
    UNIQUE (tenant_id, id)
);

CREATE TABLE refund_allocations (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    refund_id       uuid NOT NULL,
    return_line_id  uuid,
    amount          numeric(12,2) NOT NULL CHECK (amount > 0),
    FOREIGN KEY (tenant_id, refund_id) REFERENCES refunds (tenant_id, id),
    FOREIGN KEY (tenant_id, return_line_id) REFERENCES sales_return_lines (tenant_id, id)
);
