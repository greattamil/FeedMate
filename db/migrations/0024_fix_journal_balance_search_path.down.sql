CREATE OR REPLACE FUNCTION fn_check_journal_balance() RETURNS trigger AS $$
DECLARE
    v_debit numeric(14,2);
    v_credit numeric(14,2);
    v_journal_id uuid;
BEGIN
    v_journal_id := COALESCE(NEW.journal_entry_id, OLD.journal_entry_id);
    SELECT COALESCE(SUM(debit),0), COALESCE(SUM(credit),0)
      INTO v_debit, v_credit
      FROM journal_lines WHERE journal_entry_id = v_journal_id;
    IF v_debit <> v_credit THEN
        RAISE EXCEPTION 'Journal entry % is not balanced: debit=% credit=%', v_journal_id, v_debit, v_credit;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
