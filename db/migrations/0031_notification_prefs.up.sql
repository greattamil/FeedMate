-- Per-tenant, per-event push notification preferences. Independent of the
-- platform-admin "push_notifications" tenant_features kill switch (which
-- overrides all of these when disabled) — this is the shop's own dynamic
-- control over which events notify them. sale_completed defaults off: a
-- push on every routine cash sale would fatigue a busy counter, so only
-- the actionable/exception events notify out of the box.
ALTER TABLE tenant_settings ADD COLUMN notify_sale_completed boolean NOT NULL DEFAULT false;
ALTER TABLE tenant_settings ADD COLUMN notify_credit_sale boolean NOT NULL DEFAULT true;
ALTER TABLE tenant_settings ADD COLUMN notify_credit_limit_breach boolean NOT NULL DEFAULT true;
ALTER TABLE tenant_settings ADD COLUMN notify_low_stock boolean NOT NULL DEFAULT true;
ALTER TABLE tenant_settings ADD COLUMN notify_out_of_stock boolean NOT NULL DEFAULT true;
ALTER TABLE tenant_settings ADD COLUMN notify_payment_overdue boolean NOT NULL DEFAULT true;
