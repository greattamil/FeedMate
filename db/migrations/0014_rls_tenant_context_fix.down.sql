-- Reverts to the pre-fix (buggy) policy text. Only intended for emergency
-- rollback symmetry; do not run this in an environment relying on the fix.
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
                USING (tenant_id = current_setting(''app.tenant_id'', true)::uuid)
                WITH CHECK (tenant_id = current_setting(''app.tenant_id'', true)::uuid)',
            tbl.table_name
        );
    END LOOP;

    FOREACH tbl.table_name IN ARRAY nullable_tenant_tables LOOP
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation_nullable ON %I', tbl.table_name);
        EXECUTE format(
            'CREATE POLICY tenant_isolation_nullable ON %I
                USING (tenant_id = current_setting(''app.tenant_id'', true)::uuid OR tenant_id IS NULL)
                WITH CHECK (tenant_id = current_setting(''app.tenant_id'', true)::uuid OR tenant_id IS NULL)',
            tbl.table_name
        );
    END LOOP;
END
$$;

DROP POLICY IF EXISTS tenant_self_isolation ON tenants;
CREATE POLICY tenant_self_isolation ON tenants
    USING (id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (id = current_setting('app.tenant_id', true)::uuid);
