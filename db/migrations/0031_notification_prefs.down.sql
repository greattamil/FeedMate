ALTER TABLE tenant_settings DROP COLUMN IF EXISTS notify_payment_overdue;
ALTER TABLE tenant_settings DROP COLUMN IF EXISTS notify_out_of_stock;
ALTER TABLE tenant_settings DROP COLUMN IF EXISTS notify_low_stock;
ALTER TABLE tenant_settings DROP COLUMN IF EXISTS notify_credit_limit_breach;
ALTER TABLE tenant_settings DROP COLUMN IF EXISTS notify_credit_sale;
ALTER TABLE tenant_settings DROP COLUMN IF EXISTS notify_sale_completed;
