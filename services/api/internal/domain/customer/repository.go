package customer

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

var ErrNotFound = errors.New("customer not found")

type Customer struct {
	ID     uuid.UUID
	Name   string
	Status string
}

func GetByID(ctx context.Context, tx pgx.Tx, id uuid.UUID) (*Customer, error) {
	row := tx.QueryRow(ctx, `SELECT id, name, status FROM customers WHERE id = $1`, id)
	var c Customer
	if err := row.Scan(&c.ID, &c.Name, &c.Status); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &c, nil
}

// CreditProfile mirrors customer_credit_profiles. A customer with no row here
// has zero credit (credit_allowed defaults closed, not open).
type CreditProfile struct {
	CreditLimit            decimal.Decimal
	OverrideRequiredAbove  *decimal.Decimal
	RiskStatus             string
}

func GetCreditProfile(ctx context.Context, tx pgx.Tx, customerID uuid.UUID) (*CreditProfile, error) {
	row := tx.QueryRow(ctx, `
		SELECT credit_limit, override_required_above, risk_status
		FROM customer_credit_profiles WHERE customer_id = $1
	`, customerID)
	var cp CreditProfile
	if err := row.Scan(&cp.CreditLimit, &cp.OverrideRequiredAbove, &cp.RiskStatus); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			zero := decimal.Zero
			return &CreditProfile{CreditLimit: zero, RiskStatus: "NORMAL"}, nil
		}
		return nil, err
	}
	return &cp, nil
}

// OutstandingBalance is the authoritative customer receivable balance,
// derived from the append-only ledger (debits - credits) — never a
// separately maintained, independently editable field (PRD 10.1).
func OutstandingBalance(ctx context.Context, tx pgx.Tx, customerID uuid.UUID) (decimal.Decimal, error) {
	row := tx.QueryRow(ctx, `
		SELECT COALESCE(SUM(debit),0) - COALESCE(SUM(credit),0)
		FROM customer_ledger_entries WHERE customer_id = $1
	`, customerID)
	var balance decimal.Decimal
	err := row.Scan(&balance)
	return balance, err
}

type LedgerEntry struct {
	CustomerID   uuid.UUID
	DocumentType string
	DocumentID   uuid.UUID
	Debit        decimal.Decimal
	Credit       decimal.Decimal
	Description  string
	DeviceID     *uuid.UUID
	CreatedByUserID *uuid.UUID
}

// PostLedgerEntry appends one immutable ledger row. Debits increase the
// customer's receivable (e.g. a credit sale); credits decrease it (e.g. a
// receipt). Corrections must be posted as a compensating entry, never an
// UPDATE of a posted row.
func PostLedgerEntry(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, e LedgerEntry) (uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO customer_ledger_entries (
			tenant_id, customer_id, document_type, document_id, debit, credit, description,
			device_id, created_by_user_id
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
		RETURNING id
	`, tenantID, e.CustomerID, e.DocumentType, e.DocumentID, e.Debit, e.Credit, e.Description,
		e.DeviceID, e.CreatedByUserID).Scan(&id)
	return id, err
}
