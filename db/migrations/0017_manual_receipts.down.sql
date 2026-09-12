DROP INDEX IF EXISTS idx_payments_idempotency_key;
ALTER TABLE payments DROP COLUMN IF EXISTS idempotency_key;
