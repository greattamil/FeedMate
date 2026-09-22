-- A tiny per-tenant, per-entity-type sequence used to auto-generate
-- readable codes (CUST-0001, SUPP-0001, ...) instead of requiring a shop
-- owner to invent a unique code by hand every time. One row per
-- (tenant, entity_type); NextCode() below increments it atomically via an
-- upsert, so concurrent creates never collide.
CREATE TABLE entity_code_counters (
    tenant_id     uuid NOT NULL REFERENCES tenants(id),
    entity_type   varchar(20) NOT NULL,
    next_number   integer NOT NULL DEFAULT 1,
    PRIMARY KEY (tenant_id, entity_type)
);

ALTER TABLE entity_code_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE entity_code_counters FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON entity_code_counters
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);
GRANT SELECT, INSERT, UPDATE ON entity_code_counters TO app_user, app_admin;

-- Locations previously had no update timestamp at all (create + list-only
-- API), so there was no way to tell when a location's name/type was last
-- changed. Added now alongside the new update capability.
ALTER TABLE inventory_locations ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
