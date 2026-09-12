-- Migration 0011: compliance, archive, audit, attachments, integration_events, system_jobs

CREATE TABLE compliance_requests (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               uuid NOT NULL,
    document_type           varchar(30) NOT NULL CHECK (document_type IN ('E_INVOICE','E_WAY_BILL')),
    source_document_id      uuid NOT NULL,
    provider                varchar(60) NOT NULL,
    request_reference       varchar(150),
    request_payload_hash    varchar(128) NOT NULL,
    status                  varchar(20) NOT NULL DEFAULT 'PENDING'
                            CHECK (status IN ('PENDING','SUBMITTED','ACCEPTED','REJECTED','CANCELLED','ERROR')),
    submitted_at            timestamptz,
    completed_at            timestamptz,
    created_at              timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id)
);
CREATE INDEX idx_compliance_requests_source ON compliance_requests (tenant_id, document_type, source_document_id);

CREATE TABLE compliance_responses (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    request_id          uuid NOT NULL,
    response_code       varchar(30),
    status              varchar(20) NOT NULL,
    provider_reference  varchar(150),
    response_metadata   jsonb NOT NULL DEFAULT '{}'::jsonb,
    received_at         timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, request_id) REFERENCES compliance_requests (tenant_id, id)
);

CREATE TABLE compliance_documents (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               uuid NOT NULL,
    document_type           varchar(30) NOT NULL,
    status                  varchar(20) NOT NULL DEFAULT 'PENDING',
    source_document_id      uuid,
    generated_object_ref    varchar(300),
    checksum                varchar(128),
    created_at              timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE export_jobs (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    export_type     varchar(40) NOT NULL,
    date_from       date,
    date_to         date,
    filters         jsonb NOT NULL DEFAULT '{}'::jsonb,
    requested_by_user_id uuid,
    status          varchar(20) NOT NULL DEFAULT 'QUEUED' CHECK (status IN ('QUEUED','RUNNING','COMPLETED','FAILED','EXPIRED')),
    object_ref      varchar(300),
    checksum        varchar(128),
    signed_url_expires_at timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    completed_at    timestamptz
);
CREATE INDEX idx_export_jobs_tenant_status ON export_jobs (tenant_id, status);

CREATE TABLE archive_jobs (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    financial_year_id   uuid,
    cutoff_date         date NOT NULL,
    policy_version      varchar(30) NOT NULL,
    status              varchar(20) NOT NULL DEFAULT 'CANDIDATE'
                        CHECK (status IN ('CANDIDATE','PACKAGED','UPLOADED','VERIFIED','RETAINED','PURGED','FAILED')),
    started_at          timestamptz NOT NULL DEFAULT now(),
    completed_at        timestamptz,
    initiated_by_user_id uuid,
    row_count           bigint NOT NULL DEFAULT 0,
    byte_count          bigint NOT NULL DEFAULT 0,
    error               varchar(1000),
    UNIQUE (tenant_id, id)
);

CREATE TABLE archive_manifests (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    archive_job_id      uuid NOT NULL,
    schema_version      varchar(30) NOT NULL,
    date_range_from     date,
    date_range_to       date,
    table_counts        jsonb NOT NULL DEFAULT '{}'::jsonb,
    checksum_list       jsonb NOT NULL DEFAULT '{}'::jsonb,
    generated_at        timestamptz NOT NULL DEFAULT now(),
    tool_version        varchar(30),
    restore_status      varchar(20) NOT NULL DEFAULT 'UNTESTED' CHECK (restore_status IN ('UNTESTED','VERIFIED','FAILED')),
    FOREIGN KEY (tenant_id, archive_job_id) REFERENCES archive_jobs (tenant_id, id),
    UNIQUE (tenant_id, id)
);

CREATE TABLE archive_objects (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    archive_manifest_id uuid NOT NULL,
    provider            varchar(40) NOT NULL DEFAULT 'R2',
    object_key          varchar(500) NOT NULL,
    checksum            varchar(128) NOT NULL,
    encryption_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    size_bytes          bigint NOT NULL,
    status              varchar(20) NOT NULL DEFAULT 'UPLOADED' CHECK (status IN ('UPLOADED','VERIFIED','MISSING','CORRUPT')),
    FOREIGN KEY (tenant_id, archive_manifest_id) REFERENCES archive_manifests (tenant_id, id)
);

CREATE TABLE archive_restore_tests (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               uuid,
    archive_manifest_id     uuid NOT NULL,
    test_date               timestamptz NOT NULL DEFAULT now(),
    restored_environment    varchar(150),
    checksum_verified       boolean NOT NULL DEFAULT false,
    row_counts_verified     boolean NOT NULL DEFAULT false,
    sample_records_verified boolean NOT NULL DEFAULT false,
    result                  varchar(20) NOT NULL CHECK (result IN ('PASS','FAIL')),
    tester_user_id          uuid,
    notes                   varchar(1000)
);

-- =====================================================================
-- Audit — append-only from the application's perspective
-- =====================================================================
CREATE TABLE audit_logs (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid,
    actor_user_id       uuid,
    actor_device_id     uuid,
    action_code         varchar(60) NOT NULL,
    entity_type         varchar(60) NOT NULL,
    entity_id           uuid,
    request_id          uuid,
    ip_address          inet,
    user_agent          varchar(300),
    before_json         jsonb,
    after_json          jsonb,
    reason              varchar(500),
    created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_logs_entity ON audit_logs (tenant_id, entity_type, entity_id, created_at);
CREATE INDEX idx_audit_logs_action ON audit_logs (tenant_id, action_code, created_at);

-- Application role is granted INSERT/SELECT only (no UPDATE/DELETE) — enforced in migration 0012 (RLS/grants).

CREATE TABLE attachments (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    entity_type     varchar(60) NOT NULL,
    entity_id       uuid NOT NULL,
    object_provider varchar(40) NOT NULL DEFAULT 'R2',
    object_key      varchar(500) NOT NULL,
    file_name       varchar(300) NOT NULL,
    mime_type       varchar(100) NOT NULL,
    size_bytes      bigint NOT NULL,
    checksum        varchar(128) NOT NULL,
    encrypted       boolean NOT NULL DEFAULT true,
    created_by_user_id uuid,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_attachments_entity ON attachments (tenant_id, entity_type, entity_id);

CREATE TABLE integration_events (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    event_type      varchar(60) NOT NULL,
    aggregate_type  varchar(60) NOT NULL,
    aggregate_id    uuid NOT NULL,
    payload_version integer NOT NULL DEFAULT 1,
    payload         jsonb NOT NULL,
    status          varchar(20) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','PUBLISHED','FAILED')),
    retry_count     integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_integration_events_status ON integration_events (status, next_attempt_at);

CREATE TABLE system_jobs (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid,
    job_type        varchar(60) NOT NULL,
    schedule_key    varchar(100),
    status          varchar(20) NOT NULL DEFAULT 'SCHEDULED' CHECK (status IN ('SCHEDULED','RUNNING','COMPLETED','FAILED')),
    started_at      timestamptz,
    completed_at    timestamptz,
    retry_count     integer NOT NULL DEFAULT 0,
    error           varchar(1000)
);
