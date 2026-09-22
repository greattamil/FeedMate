-- This is a one-time data backfill, not a schema change — there is
-- nothing to structurally revert, and no reliable way to distinguish the
-- rows it inserted from ones a later real sale posted (both look
-- identical: a normal INVOICE debit/credit pair). Rolling back this
-- migration version number is intentionally a no-op.
SELECT 1;
