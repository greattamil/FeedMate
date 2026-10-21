-- Lets a platform admin generate a device pairing code directly for any
-- tenant (previously only an authenticated tenant user holding
-- device.manage could — a real recurring problem this session: tenants
-- forget to generate their own code and the owner has to do it for them).
-- A platform admin is never a row in `users`, so created_by_user_id is
-- relaxed to nullable and a sibling column attributes platform-admin-
-- generated codes instead, mirroring payments.created_by_user_id's
-- "who did this" precedent but split by actor type.
ALTER TABLE device_pairing_codes ALTER COLUMN created_by_user_id DROP NOT NULL;
ALTER TABLE device_pairing_codes ADD COLUMN created_by_platform_admin_id uuid REFERENCES platform_admins(id);
ALTER TABLE device_pairing_codes ADD CONSTRAINT chk_pairing_code_creator
    CHECK (
        (created_by_user_id IS NOT NULL AND created_by_platform_admin_id IS NULL) OR
        (created_by_user_id IS NULL AND created_by_platform_admin_id IS NOT NULL)
    );

-- Attributes other cross-tenant platform-admin actions (password reset,
-- device revoke) to which platform admin did it, alongside the existing
-- actor_user_id used for ordinary tenant-staff actions — the two are
-- mutually exclusive per row, same reasoning as above.
ALTER TABLE audit_logs ADD COLUMN actor_platform_admin_id uuid REFERENCES platform_admins(id);
