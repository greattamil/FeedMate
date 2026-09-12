-- Migration 0014: fix a real RLS correctness bug found via integration testing.
--
-- PostgreSQL custom GUCs (like app.tenant_id) are placeholder variables: once
-- any backend/connection has executed `set_config('app.tenant_id', <value>, true)`
-- (transaction-local) even once, that variable stays "known" to that physical
-- connection for its whole lifetime. After the transaction ends, the LOCAL value
-- reverts not to NULL but to an empty string ''. Confirmed empirically:
--
--   BEGIN; SELECT set_config('app.tenant_id','<uuid>',true); COMMIT;
--   SELECT current_setting('app.tenant_id', true); -- returns '' , not NULL
--
-- Because the Go API uses a pooled connection (pgxpool) that is reused across
-- unrelated transactions, any connection that has EVER served a tenant-scoped
-- request will thereafter return '' instead of NULL for admin-mode transactions
-- on that same connection that intentionally do not set app.tenant_id (e.g.
-- resolving which tenant a device belongs to at login). `''::uuid` raises a
-- hard cast error, breaking those admin operations outright.
--
-- The fix: every policy that casts current_setting('app.tenant_id', true) to
-- uuid must first normalize '' to NULL via NULLIF, so "never set" and "reset to
-- default" behave identically — both fail closed (NULL never equals a real
-- tenant_id) without raising a cast error.

DO $$
DECLARE
    tbl record;
    nullable_tenant_tables text[] := ARRAY['uoms','uom_conversions','payment_webhook_events','audit_logs','system_jobs','archive_restore_tests'];
BEGIN
    FOR tbl IN
        SELECT c.table_name
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_name = c.table_name AND t.table_schema = c.table_schema
        WHERE c.table_schema = 'public'
          AND c.column_name = 'tenant_id'
          AND t.table_type = 'BASE TABLE'
          AND c.table_name <> ALL (nullable_tenant_tables)
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I', tbl.table_name);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON %I
                USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)
                WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid)',
            tbl.table_name
        );
    END LOOP;

    FOREACH tbl.table_name IN ARRAY nullable_tenant_tables LOOP
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation_nullable ON %I', tbl.table_name);
        EXECUTE format(
            'CREATE POLICY tenant_isolation_nullable ON %I
                USING (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid OR tenant_id IS NULL)
                WITH CHECK (tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid OR tenant_id IS NULL)',
            tbl.table_name
        );
    END LOOP;
END
$$;

DROP POLICY IF EXISTS tenant_self_isolation ON tenants;
CREATE POLICY tenant_self_isolation ON tenants
    USING (id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

-- admin_cross_tenant policies compare app.admin_mode to the literal string 'on'
-- (no uuid cast involved), so '' vs NULL both already evaluate to false/deny
-- there and need no change.
