ALTER TABLE audit_logs DROP COLUMN actor_platform_admin_id;

ALTER TABLE device_pairing_codes DROP CONSTRAINT chk_pairing_code_creator;
ALTER TABLE device_pairing_codes DROP COLUMN created_by_platform_admin_id;
ALTER TABLE device_pairing_codes ALTER COLUMN created_by_user_id SET NOT NULL;
