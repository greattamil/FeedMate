package eod

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

var ErrNotFound = errors.New("EOD session not found")

type Session struct {
	ID              uuid.UUID
	BusinessDate    time.Time
	OpeningCash     decimal.Decimal
	CashSales       decimal.Decimal
	CashRefunds     decimal.Decimal
	CashPayouts     decimal.Decimal
	ExpectedCash    decimal.Decimal
	ActualCash      *decimal.Decimal
	Variance        *decimal.Decimal
	VarianceReason  *string
	Status          string
}

func InsertOpenSession(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, businessDate time.Time, openingCash decimal.Decimal) (uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO eod_sessions (tenant_id, business_date, opening_cash, status)
		VALUES ($1, $2, $3, 'OPEN')
		RETURNING id
	`, tenantID, businessDate, openingCash).Scan(&id)
	return id, err
}

func GetSessionByDate(ctx context.Context, tx pgx.Tx, businessDate time.Time) (*Session, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, business_date, opening_cash, cash_sales, cash_refunds, cash_payouts,
		       expected_cash, actual_cash, variance, variance_reason, status
		FROM eod_sessions WHERE business_date = $1
	`, businessDate)
	var s Session
	if err := row.Scan(&s.ID, &s.BusinessDate, &s.OpeningCash, &s.CashSales, &s.CashRefunds, &s.CashPayouts,
		&s.ExpectedCash, &s.ActualCash, &s.Variance, &s.VarianceReason, &s.Status); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &s, nil
}

// CashLedgerMovement sums the CASH-account effect of posted journal entries
// for a given business date, split by source type. This derives EOD cash
// figures from the same authoritative journal every other module posts to,
// rather than maintaining a second, independently-editable cash ledger that
// could silently drift from the real accounting record (PRD 48: never mutate
// a source ledger to fix a report — the report must derive from the events).
func GetCashJournalTotals(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, businessDate time.Time) (cashSales, cashRefunds decimal.Decimal, err error) {
	row := tx.QueryRow(ctx, `
		SELECT
			COALESCE(SUM(CASE WHEN je.source_type = 'INVOICE' THEN jl.debit ELSE 0 END), 0) AS cash_sales,
			COALESCE(SUM(CASE WHEN je.source_type = 'RETURN' THEN jl.credit ELSE 0 END), 0) AS cash_refunds
		FROM journal_lines jl
		JOIN journal_entries je ON je.id = jl.journal_entry_id
		JOIN chart_of_accounts coa ON coa.id = jl.account_id
		WHERE coa.tenant_id = $1 AND coa.account_code = 'CASH'
		  AND je.entry_date::date = $2
	`, tenantID, businessDate)
	err = row.Scan(&cashSales, &cashRefunds)
	return cashSales, cashRefunds, err
}

func CloseSession(ctx context.Context, tx pgx.Tx, sessionID uuid.UUID, cashSales, cashRefunds, cashPayouts, expectedCash, actualCash, variance decimal.Decimal, varianceReason *string, closedByUserID uuid.UUID) error {
	_, err := tx.Exec(ctx, `
		UPDATE eod_sessions
		SET cash_sales = $2, cash_refunds = $3, cash_payouts = $4, expected_cash = $5,
		    actual_cash = $6, variance = $7, variance_reason = $8,
		    status = 'CLOSED', closed_by_user_id = $9, closed_at = now()
		WHERE id = $1
	`, sessionID, cashSales, cashRefunds, cashPayouts, expectedCash, actualCash, variance, varianceReason, closedByUserID)
	return err
}

func ReopenSession(ctx context.Context, tx pgx.Tx, sessionID uuid.UUID, reopenedByUserID uuid.UUID, reason string) error {
	_, err := tx.Exec(ctx, `
		UPDATE eod_sessions
		SET status = 'REOPENED', reopened_by_user_id = $2, reopened_at = now(), reopen_reason = $3
		WHERE id = $1
	`, sessionID, reopenedByUserID, reason)
	return err
}
