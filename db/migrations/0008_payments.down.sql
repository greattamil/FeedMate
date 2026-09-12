DROP TABLE IF EXISTS refund_allocations;
DROP TABLE IF EXISTS refunds;
DROP TABLE IF EXISTS payment_webhook_events;
DROP TABLE IF EXISTS payment_allocations;
ALTER TABLE IF EXISTS invoice_tenders DROP CONSTRAINT IF EXISTS fk_invoice_tenders_payment;
DROP TABLE IF EXISTS payments;
DROP TABLE IF EXISTS payment_intents;
