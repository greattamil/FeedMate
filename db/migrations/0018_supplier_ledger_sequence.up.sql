-- Same fix as migration 0016 (customer_ledger_entries), applied proactively
-- here before it can bite: entry_date/created_at both default to now(),
-- which Postgres freezes for the whole transaction, so two supplier ledger
-- entries posted together (e.g. a GRN's inventory + payable lines) would
-- otherwise tie and fall back to comparing random gen_random_uuid() ids for
-- display order. A bigserial is monotonically increasing regardless of
-- transaction timing.
ALTER TABLE supplier_ledger_entries ADD COLUMN seq bigserial;
CREATE INDEX idx_supplier_ledger_entries_seq ON supplier_ledger_entries (supplier_id, seq DESC);

-- No explicit GRANT needed for this sequence: migration 0016 already added
-- `ALTER DEFAULT PRIVILEGES ... GRANT USAGE, SELECT ON SEQUENCES TO
-- app_user, app_admin`, which applies to every sequence created afterward
-- by the same owning role — this one included.
