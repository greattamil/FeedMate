-- One-time historical correction for the bug fixed in pos.Service.
-- FinalizeInvoice: before that fix, a fully cash/UPI-paid sale to a real
-- customer never posted anything to customer_ledger_entries at all (only
-- the credit-tendered portion of a sale did), so every such invoice
-- finalized before the fix is permanently missing from that customer's
-- ledger — the code fix only changes behavior for invoices finalized
-- *after* it deploys, it cannot retroactively fix history.
--
-- This backfills exactly what the fixed code would have posted at
-- finalize time: the full invoice as a debit, plus a credit for whatever
-- was actually paid via non-CREDIT tenders — net zero balance impact
-- (identical to today), but now visible. Guarded by NOT EXISTS so it is
-- safe to run against a database that already has some or all of these
-- entries (nothing is duplicated), and touches only FINALIZED invoices
-- that have a customer and currently have zero ledger rows at all.
WITH missing AS (
    SELECT
        si.id,
        si.tenant_id,
        si.customer_id,
        si.invoice_number,
        si.grand_total,
        si.finalized_at,
        COALESCE((
            SELECT SUM(it.amount)
            FROM invoice_tenders it
            WHERE it.invoice_id = si.id AND it.tender_method != 'CREDIT'
        ), 0) AS paid_amount
    FROM sales_invoices si
    WHERE si.status = 'FINALIZED'
      AND si.customer_id IS NOT NULL
      AND si.finalized_at IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM customer_ledger_entries cle
          WHERE cle.tenant_id = si.tenant_id AND cle.document_id = si.id
      )
)
INSERT INTO customer_ledger_entries (tenant_id, customer_id, document_type, document_id, debit, credit, description, entry_date)
SELECT tenant_id, customer_id, document_type, document_id, debit, credit, description, entry_date
FROM (
    -- kind=0 (debit) sorts before kind=1 (credit) for the same invoice, so
    -- seq (assigned in insertion order) preserves the same debit-then-
    -- credit chronology a live finalize would have produced.
    SELECT tenant_id, customer_id, 'INVOICE' AS document_type, id AS document_id,
           grand_total AS debit, 0 AS credit, 'Sale ' || invoice_number AS description,
           finalized_at AS entry_date, 0 AS kind
    FROM missing
    UNION ALL
    SELECT tenant_id, customer_id, 'INVOICE', id,
           0, paid_amount, 'Payment received at sale ' || invoice_number,
           finalized_at, 1
    FROM missing
    WHERE paid_amount > 0
) ordered
ORDER BY entry_date, kind;
