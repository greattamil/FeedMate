package supplier

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

var ErrNotFound = errors.New("supplier not found")

type Supplier struct {
	ID     uuid.UUID
	Name   string
	Status string
}

func GetByID(ctx context.Context, tx pgx.Tx, id uuid.UUID) (*Supplier, error) {
	row := tx.QueryRow(ctx, `SELECT id, legal_name, status FROM suppliers WHERE id = $1`, id)
	var s Supplier
	if err := row.Scan(&s.ID, &s.Name, &s.Status); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &s, nil
}

type LedgerEntry struct {
	SupplierID      uuid.UUID
	DocumentType    string
	DocumentID      uuid.UUID
	Debit           decimal.Decimal
	Credit          decimal.Decimal
	Description     string
	CreatedByUserID *uuid.UUID
}

// PostLedgerEntry appends one immutable supplier ledger row. Unlike the
// customer ledger (an asset — debit increases what the customer owes us),
// the supplier ledger is a liability: credit increases what we owe the
// supplier (e.g. a GRN), and debit decreases it (e.g. a payment). Outstanding
// payable = SUM(credit) - SUM(debit).
func PostLedgerEntry(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, e LedgerEntry) (uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO supplier_ledger_entries (tenant_id, supplier_id, document_type, document_id, debit, credit, description, created_by_user_id)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
		RETURNING id
	`, tenantID, e.SupplierID, e.DocumentType, e.DocumentID, e.Debit, e.Credit, e.Description, e.CreatedByUserID).Scan(&id)
	return id, err
}

func OutstandingPayable(ctx context.Context, tx pgx.Tx, supplierID uuid.UUID) (decimal.Decimal, error) {
	row := tx.QueryRow(ctx, `
		SELECT COALESCE(SUM(credit),0) - COALESCE(SUM(debit),0)
		FROM supplier_ledger_entries WHERE supplier_id = $1
	`, supplierID)
	var balance decimal.Decimal
	err := row.Scan(&balance)
	return balance, err
}
