-- customer_ledger_entries.entry_date/created_at both default to now(), which
-- Postgres freezes for the whole transaction — two entries posted in the
-- same transaction (a real occurrence: e.g. an invoice's own tender-CREDIT
-- posting alongside a same-invoice adjustment) get an identical timestamp,
-- leaving display order to fall back to comparing random gen_random_uuid()
-- ids. A Khata statement's entry order must reflect real posting order, not
-- an arbitrary UUID comparison. A bigserial is monotonically increasing
-- regardless of transaction timing, so it is the correct primary sort key.
ALTER TABLE customer_ledger_entries ADD COLUMN seq bigserial;
CREATE INDEX idx_customer_ledger_entries_seq ON customer_ledger_entries (customer_id, seq DESC);

-- Migration 0012 granted USAGE/SELECT on every sequence that existed at the
-- time, plus default privileges for future TABLES — but not future
-- SEQUENCES. A bigserial's backing sequence created by any later migration
-- (this one included) would otherwise be invisible to app_user/app_admin,
-- breaking every INSERT into that table with "permission denied for
-- sequence" — caught here by this migration's own new sequence failing
-- exactly that way against a real integration test. Fixed both narrowly (an
-- explicit grant on this sequence) and at the root cause (default
-- privileges for every sequence a future migration creates).
GRANT USAGE, SELECT ON customer_ledger_entries_seq_seq TO app_user, app_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO app_user, app_admin;
