-- Migration 0010: message_templates, notification_jobs, message_deliveries, sync_*

CREATE TABLE message_templates (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    code            varchar(60) NOT NULL,
    language_code   varchar(10) NOT NULL DEFAULT 'ta',
    version         integer NOT NULL DEFAULT 1,
    body_template   text NOT NULL,
    purpose         varchar(40) NOT NULL CHECK (purpose IN (
                        'INVOICE_RECEIPT','PAYMENT_CONFIRMATION','KHATA_REMINDER','COLLECTION_REMINDER',
                        'EXPIRY_ALERT','LOW_STOCK_ALERT','EOD_ALERT','COMPLIANCE_ALERT')),
    active          boolean NOT NULL DEFAULT true,
    UNIQUE (tenant_id, code, language_code, version),
    UNIQUE (tenant_id, id)
);

CREATE TABLE notification_jobs (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    customer_id     uuid,
    template_id     uuid NOT NULL,
    scheduled_at    timestamptz NOT NULL DEFAULT now(),
    status          varchar(20) NOT NULL DEFAULT 'QUEUED' CHECK (status IN ('QUEUED','SENT','SUPPRESSED','FAILED')),
    dedupe_key      varchar(200) NOT NULL,
    payload         jsonb NOT NULL DEFAULT '{}'::jsonb,
    suppression_reason varchar(250),
    created_at      timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES customers (tenant_id, id),
    FOREIGN KEY (tenant_id, template_id) REFERENCES message_templates (tenant_id, id),
    UNIQUE (tenant_id, dedupe_key),
    UNIQUE (tenant_id, id)
);
CREATE INDEX idx_notification_jobs_status ON notification_jobs (tenant_id, status, scheduled_at);

CREATE TABLE message_deliveries (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    notification_job_id uuid NOT NULL,
    provider            varchar(40) NOT NULL,
    provider_message_id varchar(150),
    status              varchar(20) NOT NULL DEFAULT 'QUEUED'
                        CHECK (status IN ('QUEUED','SENT','DELIVERED','READ','FAILED','SUPPRESSED')),
    sent_at             timestamptz,
    delivered_at        timestamptz,
    read_at             timestamptz,
    failed_at           timestamptz,
    error_code          varchar(60),
    retry_count         integer NOT NULL DEFAULT 0,
    FOREIGN KEY (tenant_id, notification_job_id) REFERENCES notification_jobs (tenant_id, id)
);

-- =====================================================================
-- Offline synchronization
-- =====================================================================
CREATE TABLE sync_transactions (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               uuid NOT NULL,
    device_id               uuid NOT NULL,
    client_transaction_id   uuid NOT NULL,
    local_sequence          bigint NOT NULL,
    entity_type             varchar(60) NOT NULL,
    operation_type          varchar(20) NOT NULL CHECK (operation_type IN ('CREATE','UPDATE','CANCEL')),
    payload_version         integer NOT NULL DEFAULT 1,
    payload_hash            varchar(128) NOT NULL,
    payload                 jsonb NOT NULL,
    created_at_device       timestamptz NOT NULL,
    received_at_server      timestamptz NOT NULL DEFAULT now(),
    status                  varchar(20) NOT NULL DEFAULT 'PENDING'
                            CHECK (status IN ('PENDING','ACCEPTED','DUPLICATE','CONFLICT','REJECTED')),
    authoritative_entity_id uuid,
    error_code              varchar(60),
    retry_count             integer NOT NULL DEFAULT 0,
    FOREIGN KEY (tenant_id, device_id) REFERENCES devices (tenant_id, id),
    UNIQUE (tenant_id, device_id, client_transaction_id),
    UNIQUE (tenant_id, id)
);
CREATE INDEX idx_sync_transactions_device_seq ON sync_transactions (tenant_id, device_id, local_sequence);
CREATE INDEX idx_sync_transactions_status ON sync_transactions (tenant_id, status);

CREATE TABLE sync_conflicts (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               uuid NOT NULL,
    sync_transaction_id     uuid NOT NULL,
    entity_type             varchar(60) NOT NULL,
    entity_id               uuid,
    conflict_type           varchar(40) NOT NULL, -- INSUFFICIENT_STOCK/DUPLICATE_NUMBER/STALE_MASTER_DATA/etc.
    local_payload           jsonb NOT NULL,
    server_state_reference  jsonb,
    resolution              varchar(20) NOT NULL DEFAULT 'PENDING' CHECK (resolution IN ('PENDING','RESOLVED_ACCEPT','RESOLVED_REJECT','RESOLVED_MANUAL')),
    resolved_by_user_id     uuid,
    resolved_at             timestamptz,
    created_at              timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, sync_transaction_id) REFERENCES sync_transactions (tenant_id, id)
);

CREATE TABLE sync_cursors (
    tenant_id           uuid NOT NULL,
    device_id           uuid NOT NULL,
    domain              varchar(60) NOT NULL,
    last_server_cursor  varchar(200),
    last_ack_sequence   bigint NOT NULL DEFAULT 0,
    updated_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, device_id, domain),
    FOREIGN KEY (tenant_id, device_id) REFERENCES devices (tenant_id, id)
);
