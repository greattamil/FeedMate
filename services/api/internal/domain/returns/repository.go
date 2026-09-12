package returns

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

var ErrNotFound = errors.New("not found")

type OriginalLine struct {
	ID           uuid.UUID
	InvoiceID    uuid.UUID
	ProductID    uuid.UUID
	UOMID        uuid.UUID
	Quantity     decimal.Decimal
	UnitPrice    decimal.Decimal
	TaxableValue decimal.Decimal
	TaxTotal     decimal.Decimal
}

func GetOriginalLine(ctx context.Context, tx pgx.Tx, invoiceLineID uuid.UUID) (*OriginalLine, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, invoice_id, product_id, uom_id, quantity, unit_price, taxable_value, tax_total
		FROM sales_invoice_lines WHERE id = $1
	`, invoiceLineID)
	var l OriginalLine
	if err := row.Scan(&l.ID, &l.InvoiceID, &l.ProductID, &l.UOMID, &l.Quantity, &l.UnitPrice, &l.TaxableValue, &l.TaxTotal); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &l, nil
}

// AlreadyReturnedQty sums the quantity already returned against this
// original invoice line across all POSTED returns, so a second return can
// never exceed what remains sellable-eligible (PRD 9.7 / 17: return quantity
// cannot exceed eligible sold quantity).
func AlreadyReturnedQty(ctx context.Context, tx pgx.Tx, originalLineID uuid.UUID) (decimal.Decimal, error) {
	row := tx.QueryRow(ctx, `
		SELECT COALESCE(SUM(srl.quantity), 0)
		FROM sales_return_lines srl
		JOIN sales_returns sr ON sr.id = srl.sales_return_id
		WHERE srl.original_line_id = $1 AND sr.status = 'POSTED'
	`, originalLineID)
	var qty decimal.Decimal
	err := row.Scan(&qty)
	return qty, err
}

type BatchAllocation struct {
	BatchID  uuid.UUID
	Quantity decimal.Decimal
	UnitCost decimal.Decimal
}

func GetBatchAllocations(ctx context.Context, tx pgx.Tx, invoiceLineID uuid.UUID) ([]BatchAllocation, error) {
	rows, err := tx.Query(ctx, `
		SELECT batch_id, quantity, unit_cost FROM invoice_batch_allocations WHERE invoice_line_id = $1
	`, invoiceLineID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var allocs []BatchAllocation
	for rows.Next() {
		var a BatchAllocation
		if err := rows.Scan(&a.BatchID, &a.Quantity, &a.UnitCost); err != nil {
			return nil, err
		}
		allocs = append(allocs, a)
	}
	return allocs, rows.Err()
}

type TaxLineAmount struct {
	TaxType   string
	TaxAmount decimal.Decimal
}

func GetTaxLinesForLine(ctx context.Context, tx pgx.Tx, invoiceLineID uuid.UUID) ([]TaxLineAmount, error) {
	rows, err := tx.Query(ctx, `SELECT tax_type, tax_amount FROM invoice_tax_lines WHERE invoice_line_id = $1`, invoiceLineID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TaxLineAmount
	for rows.Next() {
		var t TaxLineAmount
		if err := rows.Scan(&t.TaxType, &t.TaxAmount); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func GetBatchLocation(ctx context.Context, tx pgx.Tx, batchID uuid.UUID) (uuid.UUID, error) {
	var locationID uuid.UUID
	err := tx.QueryRow(ctx, `SELECT location_id FROM batches WHERE id = $1`, batchID).Scan(&locationID)
	return locationID, err
}

func AllocateReturnNumber(ctx context.Context, tx pgx.Tx, tenantID, financialYearID uuid.UUID) (string, error) {
	var seriesID uuid.UUID
	var prefix string
	var nextNumber int64
	var padding int
	row := tx.QueryRow(ctx, `
		SELECT id, prefix, next_number, padding
		FROM document_series
		WHERE tenant_id = $1 AND financial_year_id = $2 AND document_type = 'RETURN' AND active
		FOR UPDATE
	`, tenantID, financialYearID)
	if err := row.Scan(&seriesID, &prefix, &nextNumber, &padding); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", fmt.Errorf("no active RETURN document series configured for this financial year")
		}
		return "", err
	}
	if _, err := tx.Exec(ctx, `UPDATE document_series SET next_number = next_number + 1, updated_at = now() WHERE id = $1`, seriesID); err != nil {
		return "", err
	}
	return fmt.Sprintf("%s%0*d", prefix, padding, nextNumber), nil
}

type ReturnHeader struct {
	ID                uuid.UUID
	ReturnNumber      string
	OriginalInvoiceID uuid.UUID
	CustomerID        *uuid.UUID
	Reason            string
	Subtotal          decimal.Decimal
	TaxTotal          decimal.Decimal
	Total             decimal.Decimal
	RefundStatus      string
	CreatedByUserID   *uuid.UUID
}

func InsertReturnHeader(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, h *ReturnHeader) error {
	row := tx.QueryRow(ctx, `
		INSERT INTO sales_returns (tenant_id, return_number, original_invoice_id, customer_id, reason, status, subtotal, tax_total, total, refund_status, created_by_user_id)
		VALUES ($1,$2,$3,$4,$5,'POSTED',$6,$7,$8,$9,$10)
		RETURNING id
	`, tenantID, h.ReturnNumber, h.OriginalInvoiceID, h.CustomerID, h.Reason, h.Subtotal, h.TaxTotal, h.Total, h.RefundStatus, h.CreatedByUserID)
	return row.Scan(&h.ID)
}

type ReturnLineRecord struct {
	OriginalLineID     uuid.UUID
	ProductID          uuid.UUID
	Quantity           decimal.Decimal
	UOMID              uuid.UUID
	ConditionStatus    string
	RestockLocationID  *uuid.UUID
	RefundAmount       decimal.Decimal
}

func InsertReturnLine(ctx context.Context, tx pgx.Tx, tenantID, returnID uuid.UUID, l ReturnLineRecord) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO sales_return_lines (tenant_id, sales_return_id, original_line_id, product_id, quantity, uom_id, condition_status, restock_location_id, refund_amount)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
	`, tenantID, returnID, l.OriginalLineID, l.ProductID, l.Quantity, l.UOMID, l.ConditionStatus, l.RestockLocationID, l.RefundAmount)
	return err
}
