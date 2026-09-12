DO $$
DECLARE
    tbl record;
BEGIN
    FOR tbl IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I', tbl.tablename);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation_nullable ON %I', tbl.tablename);
        EXECUTE format('DROP POLICY IF EXISTS tenant_self_isolation ON %I', tbl.tablename);
        EXECUTE format('DROP POLICY IF EXISTS admin_cross_tenant ON %I', tbl.tablename);
        EXECUTE format('ALTER TABLE %I DISABLE ROW LEVEL SECURITY', tbl.tablename);
    END LOOP;
END
$$;
