DROP INDEX IF EXISTS idx_supplier_ledger_entries_seq;
ALTER TABLE supplier_ledger_entries DROP COLUMN IF EXISTS seq;
