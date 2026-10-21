-- Platform revenue: a catalogue of plans, each tenant's current
-- subscription state, and a durable record of manually-recorded payments
-- (no payment gateway — the platform admin records "tenant paid X", the
-- same trust model as payment.RecordManualReceipt). This is platform data,
-- not tenant data: no RLS, GRANT-only to app_admin, same boundary as
-- platform_admins (see 0021's comment).
--
-- tenants.plan_code/plan_expires_at remain as a denormalized display cache
-- for existing UI (tenant list/summary screens read only those two
-- columns) — kept in sync by subscription.Service whenever the plan/period
-- changes, but no longer the source of truth for billing logic once this
-- ships.

CREATE TABLE subscription_plans (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code               varchar(40) NOT NULL UNIQUE,
    name               varchar(120) NOT NULL,
    price              numeric(12,2) NOT NULL CHECK (price >= 0),
    currency_code      varchar(3) NOT NULL DEFAULT 'INR',
    billing_period     varchar(20) NOT NULL DEFAULT 'MONTHLY' CHECK (billing_period IN ('MONTHLY')),
    grace_period_days  integer NOT NULL DEFAULT 5 CHECK (grace_period_days >= 0),
    active             boolean NOT NULL DEFAULT true,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON subscription_plans TO app_admin;

CREATE TABLE tenant_subscriptions (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id             uuid NOT NULL UNIQUE REFERENCES tenants(id),
    plan_id               uuid NOT NULL REFERENCES subscription_plans(id),
    status                varchar(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','PAST_DUE','SUSPENDED','CANCELLED')),
    current_period_start  date NOT NULL,
    current_period_end    date NOT NULL,
    -- NULL = inherit the plan's own grace_period_days; set only to override
    -- for one specific tenant (e.g. a goodwill extension).
    grace_period_days     integer,
    past_due_since        timestamptz,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON tenant_subscriptions TO app_admin;

CREATE TABLE subscription_payments (
    id                            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                     uuid NOT NULL REFERENCES tenants(id),
    amount                        numeric(12,2) NOT NULL CHECK (amount > 0),
    currency_code                 varchar(3) NOT NULL DEFAULT 'INR',
    period_start                  date NOT NULL,
    period_end                    date NOT NULL,
    method                        varchar(20) NOT NULL CHECK (method IN ('CASH','BANK','UPI','OTHER')),
    reference                     varchar(200),
    notes                         varchar(500),
    idempotency_key               varchar(100) NOT NULL,
    recorded_by_platform_admin_id uuid NOT NULL REFERENCES platform_admins(id),
    paid_at                       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, idempotency_key)
);
CREATE INDEX idx_subscription_payments_tenant ON subscription_payments (tenant_id, paid_at DESC);
GRANT SELECT, INSERT ON subscription_payments TO app_admin;

-- Seed a starting catalogue matching the plan codes create_tenant_screen's
-- dropdown already uses (TRIAL/BASIC/PRO) so existing tenants' plan_code
-- values aren't orphaned — prices here are placeholders the platform admin
-- should correct via the Plans screen to real pricing.
INSERT INTO subscription_plans (code, name, price, grace_period_days) VALUES
    ('TRIAL', 'Trial', 0, 5),
    ('BASIC', 'Basic', 999, 5),
    ('PRO', 'Pro', 1999, 5);
