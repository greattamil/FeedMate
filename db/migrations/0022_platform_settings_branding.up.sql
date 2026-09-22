-- The single global source of truth for the app's default name/tagline/logo/
-- color, shown wherever a tenant hasn't set their own override (tenants.
-- app_display_name/logo_url/primary_color, added in 0021) — most visibly the
-- login screen, which by definition has no tenant context yet. Deliberately
-- one fixed row (id always 1), edited only by a platform admin — this is
-- exactly the "FeedMate POS" / "Andipatti Animal Feed System" text that used
-- to be hardcoded directly into the Flutter source.
CREATE TABLE platform_settings (
    id            integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    app_name      varchar(200) NOT NULL DEFAULT 'FeedMate',
    app_tagline   varchar(300) NOT NULL DEFAULT 'Multi-Tenant Retail & Wholesale POS',
    logo_url      varchar(500),
    primary_color varchar(7),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON platform_settings TO app_admin;

-- Also reachable unauthenticated (the login screen calls this before any
-- token exists) — read-only, and only ever returns this one fixed row's
-- branding fields, never anything else.
GRANT SELECT ON platform_settings TO app_user;

INSERT INTO platform_settings (id) VALUES (1);
