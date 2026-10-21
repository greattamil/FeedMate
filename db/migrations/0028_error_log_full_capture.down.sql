DROP INDEX idx_error_logs_tenant;
DROP INDEX idx_error_logs_status_code;

ALTER TABLE error_logs DROP COLUMN stack_trace;
ALTER TABLE error_logs DROP COLUMN actor_platform_admin_id;
ALTER TABLE error_logs DROP COLUMN actor_user_id;
ALTER TABLE error_logs DROP COLUMN tenant_id;
ALTER TABLE error_logs DROP COLUMN user_agent;
ALTER TABLE error_logs DROP COLUMN ip_address;
ALTER TABLE error_logs DROP COLUMN request_body;
ALTER TABLE error_logs DROP COLUMN query_params;
ALTER TABLE error_logs DROP COLUMN path;
ALTER TABLE error_logs DROP COLUMN method;
ALTER TABLE error_logs DROP COLUMN code;
