package procurement

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

var ErrNotFound = errors.New("GRN not found")

// AllocateGRNNumber atomically reserves the next number in the tenant's GRN
// document series, locking the series row so concurrent postings cannot
// collide (mirrors pos.AllocateInvoiceNumber).
func AllocateGRNNumber(ctx context.Context, tx pgx.Tx, tenantID, financialYearID uuid.UUID) (string, error) {
	var seriesID uuid.UUID
	var prefix string
	var nextNumber int64
	var padding int
	row := tx.QueryRow(ctx, `
		SELECT id, prefix, next_number, padding
		FROM document_series
		WHERE tenant_id = $1 AND financial_year_id = $2 AND document_type = 'GRN' AND active
		FOR UPDATE
	`, tenantID, financialYearID)
	if err := row.Scan(&seriesID, &prefix, &nextNumber, &padding); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", fmt.Errorf("no active GRN document series configured for this financial year")
		}
		return "", err
	}
	if _, err := tx.Exec(ctx, `UPDATE document_series SET next_number = next_number + 1, updated_at = now() WHERE id = $1`, seriesID); err != nil {
		return "", err
	}
	return fmt.Sprintf("%s%0*d", prefix, padding, nextNumber), nil
}

type GRNHeader struct {
	ID                 uuid.UUID
	GRNNumber          string
	SupplierID         uuid.UUID
	PurchaseOrderID    *uuid.UUID
	SupplierDocumentNo *string
	VehicleNo          *string
	ReceiverUserID     *uuid.UUID
	Status             string
	GrossWeightKg      *decimal.Decimal
	TareWeightKg       *decimal.Decimal
	NetWeightKg        *decimal.Decimal
	TareMethod         *string
	TareThresholdPct   *decimal.Decimal
	TareOverride       bool
	TareOverrideReason *string
	PostedAt           *time.Time
}

func InsertGRNHeader(ctx context.Context, tx pgx.Tx, tenantID, financialYearID uuid.UUID, h *GRNHeader) error {
	row := tx.QueryRow(ctx, `
		INSERT INTO goods_receipts (
			tenant_id, financial_year_id, grn_number, supplier_id, purchase_order_id, supplier_document_no,
			vehicle_no, receiver_user_id, status, gross_weight_kg, tare_weight_kg, net_weight_kg,
			tare_method, tare_threshold_pct, tare_override, tare_override_reason, posted_at
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,'POSTED',$9,$10,$11,$12,$13,$14,$15, now())
		RETURNING id, posted_at
	`, tenantID, financialYearID, h.GRNNumber, h.SupplierID, h.PurchaseOrderID, h.SupplierDocumentNo,
		h.VehicleNo, h.ReceiverUserID, h.GrossWeightKg, h.TareWeightKg, h.NetWeightKg,
		h.TareMethod, h.TareThresholdPct, h.TareOverride, h.TareOverrideReason)
	return row.Scan(&h.ID, &h.PostedAt)
}

type GRNLineRecord struct {
	ProductID       uuid.UUID
	BatchID         uuid.UUID
	LocationID      uuid.UUID
	ReceivedQty     decimal.Decimal
	ReceivedUOMID   uuid.UUID
	GrossWeightKg   *decimal.Decimal
	TareWeightKg    *decimal.Decimal
	NetWeightKg     *decimal.Decimal
	UnitCost        decimal.Decimal
	TaxProfileID    *uuid.UUID
	QualityStatus   string
	AcceptedQty     decimal.Decimal
	RejectedQty     decimal.Decimal
	ManufactureDate *time.Time
	ExpiryDate      *time.Time
}

func InsertGRNLine(ctx context.Context, tx pgx.Tx, tenantID, grnID uuid.UUID, l GRNLineRecord) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO goods_receipt_lines (
			tenant_id, goods_receipt_id, product_id, batch_id, location_id, received_qty, received_uom_id,
			gross_weight_kg, tare_weight_kg, net_weight_kg, unit_cost, tax_profile_id, quality_status,
			accepted_qty, rejected_qty, manufacture_date, expiry_date
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17)
	`, tenantID, grnID, l.ProductID, l.BatchID, l.LocationID, l.ReceivedQty, l.ReceivedUOMID,
		l.GrossWeightKg, l.TareWeightKg, l.NetWeightKg, l.UnitCost, l.TaxProfileID, l.QualityStatus,
		l.AcceptedQty, l.RejectedQty, l.ManufactureDate, l.ExpiryDate)
	return err
}

func GetTareThresholdPct(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID) (decimal.Decimal, error) {
	row := tx.QueryRow(ctx, `SELECT tare_default_max_pct FROM tenant_settings WHERE tenant_id = $1`, tenantID)
	var pct decimal.Decimal
	err := row.Scan(&pct)
	if errors.Is(err, pgx.ErrNoRows) {
		return decimal.RequireFromString("5.0"), nil // PRD A7 recommended default
	}
	return pct, err
}
