ALTER TABLE tenants DROP COLUMN primary_color;
ALTER TABLE tenants DROP COLUMN logo_url;
ALTER TABLE tenants DROP COLUMN app_display_name;
ALTER TABLE tenants DROP COLUMN plan_expires_at;
ALTER TABLE tenants DROP COLUMN plan_code;

DROP TABLE error_logs;
DROP TABLE platform_admin_sessions;
DROP TABLE platform_admins;
