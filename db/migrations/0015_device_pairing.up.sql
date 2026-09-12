-- Migration 0015: device pairing codes, enabling self-service device
-- registration without letting any unauthenticated device claim any tenant.
--
-- An already-authenticated user holding device.manage generates a
-- short-lived, single-use code; a new, unauthenticated device redeems it to
-- register itself. This mirrors common real-world device-pairing flows
-- (smart TVs, POS terminals) and is the sanctioned way a new device ever
-- learns which tenant it belongs to, other than the admin/SQL path used so
-- far in development (PRD A20: devices must have a registered identity and
-- tenant association; pairing must be revocable).

CREATE TABLE device_pairing_codes (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL REFERENCES tenants(id),
    code                varchar(12) NOT NULL,
    created_by_user_id  uuid NOT NULL,
    expires_at          timestamptz NOT NULL,
    used_at             timestamptz,
    used_by_device_id   uuid,
    created_at          timestamptz NOT NULL DEFAULT now(),
    -- Globally unique (not per-tenant): an unauthenticated device presents
    -- only the code, with no tenant context of its own, so lookup must be
    -- able to find the right tenant from the code alone.
    UNIQUE (code)
);

CREATE INDEX idx_device_pairing_codes_expiry ON device_pairing_codes (expires_at) WHERE used_at IS NULL;

ALTER TABLE device_pairing_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_pairing_codes FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON device_pairing_codes
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
CREATE POLICY admin_cross_tenant ON device_pairing_codes TO app_admin
    USING (current_setting('app.admin_mode', true) = 'on')
    WITH CHECK (current_setting('app.admin_mode', true) = 'on');
