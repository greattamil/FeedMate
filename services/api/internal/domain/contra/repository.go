package contra

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

var ErrNotFound = errors.New("contra transaction not found")

func AllocateContraNumber(ctx context.Context, tx pgx.Tx, tenantID, financialYearID uuid.UUID) (string, error) {
	var seriesID uuid.UUID
	var prefix string
	var nextNumber int64
	var padding int
	row := tx.QueryRow(ctx, `
		SELECT id, prefix, next_number, padding
		FROM document_series
		WHERE tenant_id = $1 AND financial_year_id = $2 AND document_type = 'CONTRA' AND active
		FOR UPDATE
	`, tenantID, financialYearID)
	if err := row.Scan(&seriesID, &prefix, &nextNumber, &padding); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", fmt.Errorf("no active CONTRA document series configured for this financial year")
		}
		return "", err
	}
	if _, err := tx.Exec(ctx, `UPDATE document_series SET next_number = next_number + 1, updated_at = now() WHERE id = $1`, seriesID); err != nil {
		return "", err
	}
	return fmt.Sprintf("%s%0*d", prefix, padding, nextNumber), nil
}

type ContraHeader struct {
	ID              uuid.UUID
	ContraNumber    string
	CustomerID      uuid.UUID
	TotalValue      decimal.Decimal
	ApprovedByUserID *uuid.UUID
	ApprovedAt      *time.Time
	SourceReference *string
}

func InsertContraHeader(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, h *ContraHeader) error {
	row := tx.QueryRow(ctx, `
		INSERT INTO contra_transactions (tenant_id, contra_number, customer_id, status, total_value, approved_by_user_id, approved_at, source_reference, created_by_user_id)
		VALUES ($1,$2,$3,'POSTED',$4,$5,now(),$6,$5)
		RETURNING id, approved_at
	`, tenantID, h.ContraNumber, h.CustomerID, h.TotalValue, h.ApprovedByUserID, h.SourceReference)
	return row.Scan(&h.ID, &h.ApprovedAt)
}

type ContraLineRecord struct {
	ProductID           uuid.UUID
	BatchID             *uuid.UUID
	Quantity            decimal.Decimal
	UOMID               uuid.UUID
	ValuationUnitPrice  decimal.Decimal
	Value               decimal.Decimal
	QualityStatus       string
	LocationID          uuid.UUID
}

func InsertContraLine(ctx context.Context, tx pgx.Tx, tenantID, contraID uuid.UUID, l ContraLineRecord) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO contra_lines (tenant_id, contra_transaction_id, product_id, batch_id, quantity, uom_id, valuation_unit_price, value, quality_status, location_id)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
	`, tenantID, contraID, l.ProductID, l.BatchID, l.Quantity, l.UOMID, l.ValuationUnitPrice, l.Value, l.QualityStatus, l.LocationID)
	return err
}
