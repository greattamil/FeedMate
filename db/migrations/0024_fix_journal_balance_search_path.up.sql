-- fn_check_journal_balance() referenced journal_lines unqualified, relying
-- on the session's search_path to resolve it. Standard pg_dump/pg_restore
-- output explicitly sets search_path to '' before replaying data (a
-- security best practice against search_path injection), which made this
-- deferred constraint trigger fail with "relation journal_lines does not
-- exist" the moment a data-only restore tried to load a single row into
-- journal_lines — caught migrating production data to a new database.
-- Schema-qualifying the reference makes the function correct regardless of
-- the caller's search_path.
CREATE OR REPLACE FUNCTION fn_check_journal_balance() RETURNS trigger AS $$
DECLARE
    v_debit numeric(14,2);
    v_credit numeric(14,2);
    v_journal_id uuid;
BEGIN
    v_journal_id := COALESCE(NEW.journal_entry_id, OLD.journal_entry_id);
    SELECT COALESCE(SUM(debit),0), COALESCE(SUM(credit),0)
      INTO v_debit, v_credit
      FROM public.journal_lines WHERE journal_entry_id = v_journal_id;
    IF v_debit <> v_credit THEN
        RAISE EXCEPTION 'Journal entry % is not balanced: debit=% credit=%', v_journal_id, v_debit, v_credit;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
