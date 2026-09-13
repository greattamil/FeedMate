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

func scanGRNHeader(row pgx.Row) (*GRNHeader, error) {
	var h GRNHeader
	err := row.Scan(&h.ID, &h.GRNNumber, &h.SupplierID, &h.PurchaseOrderID, &h.SupplierDocumentNo, &h.VehicleNo,
		&h.ReceiverUserID, &h.Status, &h.GrossWeightKg, &h.TareWeightKg, &h.NetWeightKg, &h.TareMethod,
		&h.TareThresholdPct, &h.TareOverride, &h.TareOverrideReason, &h.PostedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &h, nil
}

const grnHeaderColumns = `id, grn_number, supplier_id, purchase_order_id, supplier_document_no, vehicle_no,
		       receiver_user_id, status, gross_weight_kg, tare_weight_kg, net_weight_kg, tare_method,
		       tare_threshold_pct, tare_override, tare_override_reason, posted_at`

func GetGRNByID(ctx context.Context, tx pgx.Tx, id uuid.UUID) (*GRNHeader, error) {
	row := tx.QueryRow(ctx, `SELECT `+grnHeaderColumns+` FROM goods_receipts WHERE id = $1`, id)
	return scanGRNHeader(row)
}

// GRNSummary is one row of the GRN history browse list — the header plus
// the supplier's display name (goods_receipts itself keeps no name
// snapshot, so this always joins the live supplier record).
type GRNSummary struct {
	Header       GRNHeader
	SupplierName string
}

// ListGRNs returns posted GRNs newest-first, optionally filtered by a
// case-insensitive substring match on grn_number or the supplier's name.
func ListGRNs(ctx context.Context, tx pgx.Tx, query string, limit, offset int) ([]GRNSummary, int, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	var total int
	if err := tx.QueryRow(ctx, `
		SELECT COUNT(*) FROM goods_receipts g JOIN suppliers s ON s.id = g.supplier_id
		WHERE g.status = 'POSTED'
		  AND ($1 = '' OR g.grn_number ILIKE '%' || $1 || '%' OR s.legal_name ILIKE '%' || $1 || '%')
	`, query).Scan(&total); err != nil {
		return nil, 0, err
	}

	rows, err := tx.Query(ctx, `
		SELECT g.id, g.grn_number, g.supplier_id, g.purchase_order_id, g.supplier_document_no, g.vehicle_no,
		       g.receiver_user_id, g.status, g.gross_weight_kg, g.tare_weight_kg, g.net_weight_kg, g.tare_method,
		       g.tare_threshold_pct, g.tare_override, g.tare_override_reason, g.posted_at, s.legal_name
		FROM goods_receipts g JOIN suppliers s ON s.id = g.supplier_id
		WHERE g.status = 'POSTED'
		  AND ($1 = '' OR g.grn_number ILIKE '%' || $1 || '%' OR s.legal_name ILIKE '%' || $1 || '%')
		ORDER BY g.posted_at DESC
		LIMIT $2 OFFSET $3
	`, query, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var out []GRNSummary
	for rows.Next() {
		var h GRNHeader
		var supplierName string
		if err := rows.Scan(&h.ID, &h.GRNNumber, &h.SupplierID, &h.PurchaseOrderID, &h.SupplierDocumentNo, &h.VehicleNo,
			&h.ReceiverUserID, &h.Status, &h.GrossWeightKg, &h.TareWeightKg, &h.NetWeightKg, &h.TareMethod,
			&h.TareThresholdPct, &h.TareOverride, &h.TareOverrideReason, &h.PostedAt, &supplierName); err != nil {
			return nil, 0, err
		}
		out = append(out, GRNSummary{Header: h, SupplierName: supplierName})
	}
	return out, total, rows.Err()
}

// GRNLineDetail is the read-side shape of one posted GRN line, for the
// detail/history view.
type GRNLineDetail struct {
	ProductName   string
	SKU           string
	BatchCode     string
	ReceivedQty   decimal.Decimal
	UOMCode       string
	UnitCost      decimal.Decimal
	QualityStatus string
}

func ListGRNLineDetails(ctx context.Context, tx pgx.Tx, grnID uuid.UUID) ([]GRNLineDetail, error) {
	rows, err := tx.Query(ctx, `
		SELECT p.name, p.sku, COALESCE(b.batch_code, ''), l.received_qty, u.code, l.unit_cost, l.quality_status
		FROM goods_receipt_lines l
		JOIN products p ON p.id = l.product_id
		JOIN uoms u ON u.id = l.received_uom_id
		LEFT JOIN batches b ON b.id = l.batch_id
		WHERE l.goods_receipt_id = $1
		ORDER BY l.id
	`, grnID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []GRNLineDetail
	for rows.Next() {
		var l GRNLineDetail
		if err := rows.Scan(&l.ProductName, &l.SKU, &l.BatchCode, &l.ReceivedQty, &l.UOMCode, &l.UnitCost, &l.QualityStatus); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

func GetSupplierName(ctx context.Context, tx pgx.Tx, supplierID uuid.UUID) (string, error) {
	var name string
	err := tx.QueryRow(ctx, `SELECT legal_name FROM suppliers WHERE id = $1`, supplierID).Scan(&name)
	return name, err
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
