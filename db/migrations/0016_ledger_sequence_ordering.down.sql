DROP INDEX IF EXISTS idx_customer_ledger_entries_seq;
ALTER TABLE customer_ledger_entries DROP COLUMN IF EXISTS seq;
