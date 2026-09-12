package supplier

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

var ErrNotFound = errors.New("supplier not found")

type Supplier struct {
	ID               uuid.UUID
	SupplierCode     string
	Name             string
	TradeName        *string
	GSTIN            *string
	Phone            *string
	Email            *string
	PaymentTermsDays int
	Status           string
}

func GetByID(ctx context.Context, tx pgx.Tx, id uuid.UUID) (*Supplier, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, supplier_code, legal_name, trade_name, gstin, phone, email, payment_terms_days, status
		FROM suppliers WHERE id = $1
	`, id)
	return scanSupplier(row)
}

func scanSupplier(row pgx.Row) (*Supplier, error) {
	var s Supplier
	if err := row.Scan(&s.ID, &s.SupplierCode, &s.Name, &s.TradeName, &s.GSTIN, &s.Phone, &s.Email, &s.PaymentTermsDays, &s.Status); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &s, nil
}

// Create inserts a new supplier. Mirrors customer.Create's shape; unlike a
// customer, a supplier's "credit limit" column (how much we're allowed to
// owe them) is rarely used in practice for a small retail shop's suppliers
// and is left unset here — nothing in this system currently enforces it.
func Create(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, s *Supplier) error {
	row := tx.QueryRow(ctx, `
		INSERT INTO suppliers (tenant_id, supplier_code, legal_name, trade_name, gstin, phone, email, payment_terms_days, status)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,'ACTIVE')
		RETURNING id, status
	`, tenantID, s.SupplierCode, s.Name, s.TradeName, s.GSTIN, s.Phone, s.Email, s.PaymentTermsDays)
	return row.Scan(&s.ID, &s.Status)
}

// List returns active suppliers, optionally filtered by a case-insensitive
// substring match on name/supplier_code/phone/GSTIN.
func List(ctx context.Context, tx pgx.Tx, query string, limit int) ([]Supplier, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	rows, err := tx.Query(ctx, `
		SELECT id, supplier_code, legal_name, trade_name, gstin, phone, email, payment_terms_days, status
		FROM suppliers
		WHERE status = 'ACTIVE'
		  AND ($1 = '' OR legal_name ILIKE '%' || $1 || '%' OR supplier_code ILIKE '%' || $1 || '%'
		       OR phone ILIKE '%' || $1 || '%' OR gstin ILIKE '%' || $1 || '%')
		ORDER BY legal_name
		LIMIT $2
	`, query, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Supplier
	for rows.Next() {
		var s Supplier
		if err := rows.Scan(&s.ID, &s.SupplierCode, &s.Name, &s.TradeName, &s.GSTIN, &s.Phone, &s.Email, &s.PaymentTermsDays, &s.Status); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
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

// LedgerEntryRecord is the read-side shape for a supplier payable statement
// view — mirrors customer.LedgerEntryRecord.
type LedgerEntryRecord struct {
	ID           uuid.UUID
	EntryDate    time.Time
	DocumentType string
	DocumentID   uuid.UUID
	Debit        decimal.Decimal
	Credit       decimal.Decimal
	Description  *string
}

// ListLedger returns a supplier's ledger entries newest-first. Ordered by
// seq (see migration 0018), not entry_date, for the same reason as
// customer.ListLedger: entry_date/created_at freeze per-transaction under
// Postgres's now(), so two entries posted together would otherwise tie and
// fall back to comparing random UUIDs.
func ListLedger(ctx context.Context, tx pgx.Tx, supplierID uuid.UUID, limit int) ([]LedgerEntryRecord, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	rows, err := tx.Query(ctx, `
		SELECT id, entry_date, document_type, document_id, debit, credit, description
		FROM supplier_ledger_entries
		WHERE supplier_id = $1
		ORDER BY seq DESC
		LIMIT $2
	`, supplierID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []LedgerEntryRecord
	for rows.Next() {
		var r LedgerEntryRecord
		if err := rows.Scan(&r.ID, &r.EntryDate, &r.DocumentType, &r.DocumentID, &r.Debit, &r.Credit, &r.Description); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
