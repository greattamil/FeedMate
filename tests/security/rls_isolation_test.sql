-- PostgreSQL Row-Level Security tenant-isolation test suite.
-- Run via scripts/test-rls.sh against a freshly migrated database.
-- Asserts PRD v1.1 A1 / DB spec section 53 (RLS Test Matrix) as executable checks.
-- Any failed assertion raises an exception and the script's exit code is non-zero.

\set ON_ERROR_STOP on
SET client_min_messages TO WARNING;

-- ---------------------------------------------------------------------
-- Fixture setup — only app_admin with admin_mode may create tenants.
-- ---------------------------------------------------------------------
\c feedmate app_admin
SELECT set_config('app.admin_mode', 'on', false);

INSERT INTO tenants (id, legal_name, address_line1, city, state_code) VALUES
    ('aaaaaaaa-0000-0000-0000-000000000001','RLS Test Tenant A','1 Main St','Andipatti','TN'),
    ('aaaaaaaa-0000-0000-0000-000000000002','RLS Test Tenant B','2 Main St','Andipatti','TN')
ON CONFLICT (id) DO NOTHING;

INSERT INTO categories (tenant_id, name) VALUES
    ('aaaaaaaa-0000-0000-0000-000000000001','RLS_CAT_A'),
    ('aaaaaaaa-0000-0000-0000-000000000002','RLS_CAT_B')
ON CONFLICT DO NOTHING;

SELECT set_config('app.admin_mode', 'off', false);

-- ---------------------------------------------------------------------
-- Assertions as app_user (the role the API actually connects as).
-- ---------------------------------------------------------------------
\c feedmate app_user

-- 1. Fresh session, no tenant context => zero rows (fail closed).
DO $$
DECLARE cnt int;
BEGIN
    SELECT count(*) INTO cnt FROM categories WHERE name LIKE 'RLS_CAT_%';
    IF cnt <> 0 THEN
        RAISE EXCEPTION 'RLS TEST FAILED: expected 0 rows with no tenant context, got %', cnt;
    END IF;
    RAISE NOTICE 'PASS: no tenant context returns zero rows';
END $$;

-- 2. Tenant A context sees only its own row.
SELECT set_config('app.tenant_id', 'aaaaaaaa-0000-0000-0000-000000000001', false);
DO $$
DECLARE cnt int;
BEGIN
    SELECT count(*) INTO cnt FROM categories WHERE name LIKE 'RLS_CAT_%';
    IF cnt <> 1 THEN
        RAISE EXCEPTION 'RLS TEST FAILED: tenant A expected to see exactly 1 row, got %', cnt;
    END IF;
    RAISE NOTICE 'PASS: tenant A sees only its own row';
END $$;

-- 3. Tenant A cannot INSERT a row tagged with tenant B's id.
DO $$
BEGIN
    BEGIN
        INSERT INTO categories (tenant_id, name) VALUES ('aaaaaaaa-0000-0000-0000-000000000002','RLS_HOSTILE');
        RAISE EXCEPTION 'RLS TEST FAILED: cross-tenant insert was not denied';
    EXCEPTION WHEN insufficient_privilege OR check_violation THEN
        RAISE NOTICE 'PASS: cross-tenant insert denied (%)', SQLERRM;
    END;
END $$;

-- 4. Tenant A cannot UPDATE tenant B's row even with its known ID.
DO $$
DECLARE affected int;
BEGIN
    UPDATE categories SET name = 'RLS_HACKED' WHERE name = 'RLS_CAT_B';
    GET DIAGNOSTICS affected = ROW_COUNT;
    IF affected <> 0 THEN
        RAISE EXCEPTION 'RLS TEST FAILED: cross-tenant update affected % rows', affected;
    END IF;
    RAISE NOTICE 'PASS: cross-tenant update affects zero rows';
END $$;

-- 5. Tenant A cannot DELETE tenant B's row; the row survives under tenant B's own context.
DO $$
DECLARE affected int;
BEGIN
    DELETE FROM categories WHERE name = 'RLS_CAT_B';
    GET DIAGNOSTICS affected = ROW_COUNT;
    IF affected <> 0 THEN
        RAISE EXCEPTION 'RLS TEST FAILED: cross-tenant delete affected % rows', affected;
    END IF;
END $$;

SELECT set_config('app.tenant_id', 'aaaaaaaa-0000-0000-0000-000000000002', false);
DO $$
DECLARE cnt int;
BEGIN
    SELECT count(*) INTO cnt FROM categories WHERE name = 'RLS_CAT_B';
    IF cnt <> 1 THEN
        RAISE EXCEPTION 'RLS TEST FAILED: tenant B row did not survive tenant A delete attempt';
    END IF;
    RAISE NOTICE 'PASS: tenant B row survives cross-tenant delete attempt';
END $$;

-- ---------------------------------------------------------------------
-- Cleanup (as app_admin so RLS does not block the teardown).
-- ---------------------------------------------------------------------
\c feedmate app_admin
SELECT set_config('app.admin_mode', 'on', false);
DELETE FROM categories WHERE name LIKE 'RLS_CAT_%' OR name = 'RLS_HACKED';
DELETE FROM tenants WHERE id IN ('aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002');
SELECT set_config('app.admin_mode', 'off', false);

\echo 'ALL RLS ISOLATION TESTS PASSED'
