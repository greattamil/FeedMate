-- Migration 0002: users, roles, permissions, devices

CREATE TABLE users (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL REFERENCES tenants(id),
    username            varchar(120) NOT NULL,
    email               varchar(254),
    phone               varchar(30),
    password_hash       varchar(255) NOT NULL,
    pin_hash            varchar(255),
    display_name        varchar(150) NOT NULL,
    status              varchar(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DISABLED','LOCKED')),
    last_login_at       timestamptz,
    failed_login_count  integer NOT NULL DEFAULT 0,
    locked_until        timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, username),
    UNIQUE (tenant_id, id)
);

CREATE TABLE roles (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenants(id),
    name            varchar(80) NOT NULL,
    description     varchar(250),
    is_system_role  boolean NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name),
    UNIQUE (tenant_id, id)
);

-- Permissions are global (not tenant-scoped) — they define the fixed system permission catalogue.
CREATE TABLE permissions (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code            varchar(100) NOT NULL UNIQUE, -- e.g. invoice.finalize, stock.adjust
    description     varchar(250) NOT NULL
);

CREATE TABLE role_permissions (
    tenant_id       uuid NOT NULL,
    role_id         uuid NOT NULL,
    permission_id   uuid NOT NULL REFERENCES permissions(id),
    PRIMARY KEY (role_id, permission_id),
    FOREIGN KEY (tenant_id, role_id) REFERENCES roles (tenant_id, id)
);

CREATE TABLE user_roles (
    tenant_id   uuid NOT NULL,
    user_id     uuid NOT NULL,
    role_id     uuid NOT NULL,
    assigned_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, role_id),
    FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id),
    FOREIGN KEY (tenant_id, role_id) REFERENCES roles (tenant_id, id)
);

CREATE TABLE devices (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenants(id),
    device_uuid     uuid NOT NULL,
    display_name    varchar(150) NOT NULL,
    platform        varchar(30) NOT NULL CHECK (platform IN ('ANDROID','IOS','WEB','OTHER')),
    app_version     varchar(30),
    status          varchar(20) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACTIVE','REVOKED','DEACTIVATED')),
    security_state  varchar(20) NOT NULL DEFAULT 'UNKNOWN' CHECK (security_state IN ('UNKNOWN','TRUSTED','ROOTED_JAILBROKEN','FLAGGED')),
    last_seen_at    timestamptz,
    last_sync_at    timestamptz,
    registered_at   timestamptz NOT NULL DEFAULT now(),
    deactivated_at  timestamptz,
    UNIQUE (tenant_id, device_uuid),
    UNIQUE (tenant_id, id)
);

CREATE TABLE device_sessions (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    device_id           uuid NOT NULL,
    user_id             uuid NOT NULL,
    refresh_token_hash  varchar(255) NOT NULL,
    issued_at           timestamptz NOT NULL DEFAULT now(),
    expires_at          timestamptz NOT NULL,
    revoked_at          timestamptz,
    ip_address          inet,
    user_agent          varchar(300),
    FOREIGN KEY (tenant_id, device_id) REFERENCES devices (tenant_id, id),
    FOREIGN KEY (tenant_id, user_id) REFERENCES users (tenant_id, id)
);

CREATE INDEX idx_device_sessions_device ON device_sessions (tenant_id, device_id);
CREATE INDEX idx_users_tenant_status ON users (tenant_id, status);

-- Seed the fixed system permission catalogue (global, not tenant-scoped).
INSERT INTO permissions (code, description) VALUES
    ('tenant.admin', 'Full tenant administration'),
    ('user.manage', 'Create/update/disable users and role assignments'),
    ('product.manage', 'Create/update product master, UOM, tax, pricing'),
    ('tax.configure', 'Configure tax profiles and HSN mapping'),
    ('price.override', 'Override price floors and discount limits'),
    ('supplier.manage', 'Create/update supplier master'),
    ('po.create', 'Create purchase orders'),
    ('po.approve', 'Approve purchase orders'),
    ('grn.post', 'Post goods receipt notes'),
    ('grn.override_tare', 'Override tare threshold validation on GRN'),
    ('stock.adjust', 'Post manual stock adjustments'),
    ('stock.count', 'Perform and post physical stock counts'),
    ('batch.quarantine', 'Quarantine or release a batch'),
    ('pos.sell', 'Operate point of sale / create invoices'),
    ('invoice.finalize', 'Finalize sales invoices'),
    ('invoice.cancel', 'Cancel a finalized invoice'),
    ('invoice.reprint', 'Reprint a finalized invoice'),
    ('return.create', 'Create sales returns'),
    ('refund.approve', 'Approve refunds'),
    ('credit.override', 'Override customer credit limit at POS'),
    ('credit.configure', 'Configure customer credit limits/tiers'),
    ('contra.approve', 'Approve contra/buy-back transactions'),
    ('payment.refund', 'Issue payment refunds'),
    ('payment.reconcile', 'Perform manual payment reconciliation adjustments'),
    ('cash.eod_close', 'Close end-of-day cash session'),
    ('eod.reopen', 'Reopen a closed EOD session'),
    ('report.view', 'View standard reports'),
    ('report.export', 'Generate/export report data'),
    ('compliance.submit', 'Submit compliance/e-way-bill requests'),
    ('archive.approve', 'Approve archive/purge operations'),
    ('archive.purge', 'Execute an archival purge'),
    ('device.manage', 'Register/revoke devices'),
    ('audit.view', 'View audit logs');
