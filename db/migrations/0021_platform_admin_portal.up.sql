-- Platform-level administration lives entirely outside the tenant model —
-- these tables carry no tenant_id and are granted only to app_admin, never
-- app_user, so a bug anywhere in ordinary tenant-scoped request handling
-- can never read or write them even by accident. No RLS is needed on them:
-- RLS enforces per-tenant isolation, and these rows aren't tenant data at
-- all — the access boundary here is "which Postgres role can even see the
-- table", enforced by GRANT alone.
CREATE TABLE platform_admins (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    username      varchar(60) NOT NULL UNIQUE,
    password_hash varchar(200) NOT NULL,
    display_name  varchar(200) NOT NULL,
    status        varchar(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DISABLED')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON platform_admins TO app_admin;

CREATE TABLE platform_admin_sessions (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    platform_admin_id  uuid NOT NULL REFERENCES platform_admins(id),
    refresh_token_hash varchar(64) NOT NULL,
    expires_at         timestamptz NOT NULL,
    revoked_at         timestamptz,
    created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_platform_admin_sessions_hash ON platform_admin_sessions(refresh_token_hash);
GRANT SELECT, INSERT, UPDATE ON platform_admin_sessions TO app_admin;

-- A durable, queryable record of every 5xx the API has returned. Until now
-- these only ever reached stdout (docker logs) via slog — fine for live
-- tailing, useless for "show me what broke for tenant X last week" or a
-- platform dashboard. Keyed by the same request_id already echoed back to
-- the client in the error envelope, so a support conversation referencing
-- a request id can be looked up directly.
CREATE TABLE error_logs (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id  uuid,
    status_code integer NOT NULL,
    message     text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_error_logs_created_at ON error_logs(created_at DESC);
GRANT SELECT, INSERT ON error_logs TO app_admin;

-- Plan/branding fields a platform admin controls per tenant — deliberately
-- exposed by no tenant-scoped endpoint, so a shop owner can never change
-- their own plan tier, expiry, or (once whitelabeled) app identity.
ALTER TABLE tenants ADD COLUMN plan_code varchar(40) NOT NULL DEFAULT 'TRIAL';
ALTER TABLE tenants ADD COLUMN plan_expires_at timestamptz;
ALTER TABLE tenants ADD COLUMN app_display_name varchar(200);
ALTER TABLE tenants ADD COLUMN logo_url varchar(500);
ALTER TABLE tenants ADD COLUMN primary_color varchar(7);
