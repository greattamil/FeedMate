package accounting

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

var ErrNoActiveFinancialYear = errors.New("tenant has no active (OPEN) financial year")

// GetActiveFinancialYear returns the tenant's current open financial year.
// Every posted journal/invoice/PO/GRN/etc. number series is scoped to one of
// these; there must always be exactly one OPEN year for posting to succeed
// (PRD A13 — financial year configuration).
func GetActiveFinancialYear(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID) (uuid.UUID, error) {
	row := tx.QueryRow(ctx, `
		SELECT id FROM financial_years WHERE tenant_id = $1 AND status = 'OPEN'
		ORDER BY start_date DESC LIMIT 1
	`, tenantID)
	var id uuid.UUID
	if err := row.Scan(&id); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return uuid.Nil, ErrNoActiveFinancialYear
		}
		return uuid.Nil, err
	}
	return id, nil
}

// GetOrCreateAccount looks up a chart-of-accounts row by its stable code,
// creating it with sane defaults on first use. This lets the POS/procurement/
// Khata engines post against a small set of system accounts (CASH, UPI,
// SALES, TAX_PAYABLE, RECEIVABLE, ...) without requiring a full accounting
// setup wizard before the core business loop works — a real accountant is
// still expected to review/remap the chart of accounts before go-live
// (PRD 17: exact chart-of-accounts treatment must be configured with the
// accountant).
func GetOrCreateAccount(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, code, name, accountType string) (uuid.UUID, error) {
	row := tx.QueryRow(ctx, `SELECT id FROM chart_of_accounts WHERE tenant_id = $1 AND account_code = $2`, tenantID, code)
	var id uuid.UUID
	err := row.Scan(&id)
	if err == nil {
		return id, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, err
	}
	err = tx.QueryRow(ctx, `
		INSERT INTO chart_of_accounts (tenant_id, account_code, account_name, account_type)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (tenant_id, account_code) DO UPDATE SET account_code = EXCLUDED.account_code
		RETURNING id
	`, tenantID, code, name, accountType).Scan(&id)
	return id, err
}

type JournalLine struct {
	AccountID   uuid.UUID
	Debit       decimal.Decimal
	Credit      decimal.Decimal
	CustomerID  *uuid.UUID
	SupplierID  *uuid.UUID
	Description string
}

// PostJournal creates a journal entry with its lines. A PostgreSQL deferred
// constraint trigger (fn_check_journal_balance, migration 0009) verifies
// sum(debit) = sum(credit) at transaction commit — this function does not
// need to (and should not) re-implement that check in Go, but callers should
// still construct balanced lines deliberately rather than relying on the
// trigger to catch programmer error.
func PostJournal(ctx context.Context, tx pgx.Tx, tenantID, financialYearID uuid.UUID, journalNumber, sourceType string, sourceID uuid.UUID, description string, lines []JournalLine) (uuid.UUID, error) {
	if len(lines) < 2 {
		return uuid.Nil, fmt.Errorf("a journal entry needs at least two lines")
	}
	var journalID uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO journal_entries (tenant_id, financial_year_id, journal_number, source_type, source_id, description)
		VALUES ($1,$2,$3,$4,$5,$6)
		RETURNING id
	`, tenantID, financialYearID, journalNumber, sourceType, sourceID, description).Scan(&journalID)
	if err != nil {
		return uuid.Nil, fmt.Errorf("insert journal entry: %w", err)
	}

	for _, l := range lines {
		_, err := tx.Exec(ctx, `
			INSERT INTO journal_lines (tenant_id, journal_entry_id, account_id, debit, credit, customer_id, supplier_id, description)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
		`, tenantID, journalID, l.AccountID, l.Debit, l.Credit, l.CustomerID, l.SupplierID, l.Description)
		if err != nil {
			return uuid.Nil, fmt.Errorf("insert journal line: %w", err)
		}
	}
	return journalID, nil
}
