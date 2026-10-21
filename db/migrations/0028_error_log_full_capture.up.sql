-- Full debug-level capture for every error response, not just 500s: the
-- method/path/query/redacted-body that produced it, caller IP/user-agent,
-- actor/tenant context, and (for a recovered panic) a real stack trace.
-- Previously error_logs only ever captured status_code+message for
-- CodeInternal responses — every 400/404/409/etc, the vast majority of
-- real errors, left no trace at all, and a panic's actual cause/stack was
-- lost to stdout only.
ALTER TABLE error_logs ADD COLUMN code varchar(60);
ALTER TABLE error_logs ADD COLUMN method varchar(10);
ALTER TABLE error_logs ADD COLUMN path varchar(500);
ALTER TABLE error_logs ADD COLUMN query_params text;
ALTER TABLE error_logs ADD COLUMN request_body jsonb;
ALTER TABLE error_logs ADD COLUMN ip_address inet;
ALTER TABLE error_logs ADD COLUMN user_agent varchar(300);
ALTER TABLE error_logs ADD COLUMN tenant_id uuid;
ALTER TABLE error_logs ADD COLUMN actor_user_id uuid;
ALTER TABLE error_logs ADD COLUMN actor_platform_admin_id uuid;
ALTER TABLE error_logs ADD COLUMN stack_trace text;

CREATE INDEX idx_error_logs_status_code ON error_logs (status_code, created_at DESC);
CREATE INDEX idx_error_logs_tenant ON error_logs (tenant_id, created_at DESC);
