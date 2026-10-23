-- Platform-admin live cloud usage dashboard: tracks how close each free-tier
-- provider (Google Cloud, Cloudflare, Aiven) is to its usage ceiling, polled
-- periodically from each provider's own API (see internal/domain/cloudusage)
-- rather than queried live on every page load, and alerts when a configured
-- threshold is breached.

CREATE TABLE cloud_usage_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provider varchar(20) NOT NULL,       -- 'gcp' | 'cloudflare' | 'aiven'
    metric_key varchar(60) NOT NULL,     -- e.g. 'cloud_run_requests', 'r2_storage_bytes'
    label varchar(120) NOT NULL,
    used_value numeric NOT NULL,
    limit_value numeric,                 -- null when no ceiling is known
    limit_is_live boolean NOT NULL DEFAULT true, -- false for GCP's published-constant limits
    unit varchar(20) NOT NULL,           -- 'count' | 'bytes' | 'vcpu_seconds' | 'gib_seconds'
    raw_json jsonb,
    captured_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_cloud_usage_snapshots_latest ON cloud_usage_snapshots (provider, metric_key, captured_at DESC);

CREATE TABLE cloud_usage_thresholds (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provider varchar(20) NOT NULL,
    metric_key varchar(60) NOT NULL,
    warning_pct numeric NOT NULL DEFAULT 70,
    critical_pct numeric NOT NULL DEFAULT 90,
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (provider, metric_key)
);

CREATE TABLE cloud_usage_alerts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provider varchar(20) NOT NULL,
    metric_key varchar(60) NOT NULL,
    severity varchar(20) NOT NULL,       -- 'warning' | 'critical'
    message text NOT NULL,
    pct_used numeric NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz
);
CREATE INDEX idx_cloud_usage_alerts_active ON cloud_usage_alerts (resolved_at) WHERE resolved_at IS NULL;

INSERT INTO cloud_usage_thresholds (provider, metric_key, warning_pct, critical_pct) VALUES
    ('gcp', 'cloud_run_requests', 70, 90),
    ('gcp', 'cloud_run_billable_instance_seconds', 70, 90),
    ('cloudflare', 'workers_requests_today', 70, 90),
    ('cloudflare', 'r2_storage_bytes', 70, 90),
    ('cloudflare', 'r2_operations_total', 70, 90),
    ('aiven', 'postgres_disk_bytes', 70, 90);
