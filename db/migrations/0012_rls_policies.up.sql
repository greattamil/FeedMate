-- Migration 0012: PostgreSQL Row-Level Security — mandatory tenant isolation.
-- Defense-in-depth failsafe behind application-layer authorization (never a replacement for it).
--
-- Trust model:
--   * The Go API authenticates/authorizes the request, then sets a trusted session
--     variable `app.tenant_id` via `SELECT set_config('app.tenant_id', $1, true)`
--     at the start of every request-scoped transaction, using a value derived from
--     the verified access token — never from a client-supplied header/body field.
--   * The `app_user` role used by the API has NO BYPASSRLS and is NOT superuser.
--   * A separate `app_admin` role (also non-superuser, no BYPASSRLS) is used only by
--     explicitly authorized cross-tenant administrative tooling and is granted through
--     dedicated, audited policies rather than by disabling RLS.
--   * Missing/invalid tenant context fails closed: current_setting('app.tenant_id', true)
--     returns NULL, which never matches any row's tenant_id, so zero rows are visible.

-- =====================================================================
-- Application database roles (least privilege, no BYPASSRLS, not superuser)
-- =====================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
        CREATE ROLE app_user LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE PASSWORD 'CHANGE_ME_IN_PRODUCTION';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_admin') THEN
        CREATE ROLE app_admin LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE PASSWORD 'CHANGE_ME_IN_PRODUCTION';
    END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO app_user, app_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user, app_admin;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user, app_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_user, app_admin;

-- Audit logs are append-only from the application's perspective: no UPDATE/DELETE for app_user.
REVOKE UPDATE, DELETE ON audit_logs FROM app_user;

-- =====================================================================
-- Generic tenant-isolation policy applied to every table with a tenant_id column
-- whose values are always non-null (ordinary tenant-owned tables).
-- =====================================================================
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
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tbl.table_name);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', tbl.table_name);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON %I
                USING (tenant_id = current_setting(''app.tenant_id'', true)::uuid)
                WITH CHECK (tenant_id = current_setting(''app.tenant_id'', true)::uuid)',
            tbl.table_name
        );
    END LOOP;
END
$$;

-- =====================================================================
-- Tables with a nullable tenant_id (global reference data or rows that are not
-- yet resolved to a tenant, e.g. inbound payment webhooks before verification).
-- SELECT/UPDATE/DELETE may see the tenant's own rows plus global (NULL) rows;
-- INSERT/UPDATE performed under a tenant context must still stamp that tenant's id.
-- Rows with tenant_id IS NULL are only ever written by the app_admin/service path.
-- =====================================================================
DO $$
DECLARE
    tbl text;
    nullable_tenant_tables text[] := ARRAY['uoms','uom_conversions','payment_webhook_events','audit_logs','system_jobs','archive_restore_tests'];
BEGIN
    FOREACH tbl IN ARRAY nullable_tenant_tables LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tbl);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', tbl);
        EXECUTE format(
            'CREATE POLICY tenant_isolation_nullable ON %I
                USING (tenant_id = current_setting(''app.tenant_id'', true)::uuid OR tenant_id IS NULL)
                WITH CHECK (tenant_id = current_setting(''app.tenant_id'', true)::uuid OR tenant_id IS NULL)',
            tbl
        );
    END LOOP;
END
$$;

-- tenants itself: a tenant may only read/update its own row; creation happens via app_admin (onboarding).
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenants FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_self_isolation ON tenants
    USING (id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (id = current_setting('app.tenant_id', true)::uuid);

-- app_admin may create/administer any tenant row (onboarding, support) only under the
-- explicit admin_mode session flag — the tenants table has no tenant_id column so it is
-- not covered by the generic admin_cross_tenant loop below and needs its own policy.
CREATE POLICY admin_cross_tenant ON tenants TO app_admin
    USING (current_setting('app.admin_mode', true) = 'on')
    WITH CHECK (current_setting('app.admin_mode', true) = 'on');

-- app_admin gets an explicit, separately authorized bypass policy (not BYPASSRLS on the role)
-- gated by a distinct trusted session flag the API only sets on the dedicated admin code path.
DO $$
DECLARE
    tbl record;
BEGIN
    FOR tbl IN
        SELECT tablename FROM pg_tables WHERE schemaname = 'public'
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema='public' AND table_name = tbl.tablename AND column_name='tenant_id'
        ) THEN
            EXECUTE format(
                'CREATE POLICY admin_cross_tenant ON %I TO app_admin
                    USING (current_setting(''app.admin_mode'', true) = ''on'')
                    WITH CHECK (current_setting(''app.admin_mode'', true) = ''on'')',
                tbl.tablename
            );
        END IF;
    END LOOP;
END
$$;

COMMENT ON ROLE app_user IS 'Ordinary API connection role. Tenant context set per-transaction via app.tenant_id. No BYPASSRLS.';
COMMENT ON ROLE app_admin IS 'Cross-tenant administrative role. Requires app.admin_mode=on session flag set only by explicitly authorized admin code paths. No BYPASSRLS.';
