-- Cash (or bank/other) receipts collected in person have no payment
-- provider to confirm them via webhook — the cashier physically holding the
-- money *is* the confirmation, the same trust boundary the system already
-- accepts for a CASH tender at POS checkout (see pos.postSaleJournal). This
-- column lets a manual receipt be posted idempotently (a cashier
-- double-tapping "Record Receipt" must not double-credit a customer's
-- Khata), mirroring payment_intents.idempotency_key's existing pattern.
ALTER TABLE payments ADD COLUMN idempotency_key varchar(150);
CREATE UNIQUE INDEX idx_payments_idempotency_key ON payments (tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
