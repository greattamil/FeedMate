package inventory

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

var (
	ErrNotFound           = errors.New("not found")
	ErrInsufficientStock  = errors.New("insufficient stock")
)

type Batch struct {
	ID            uuid.UUID
	ProductID     uuid.UUID
	SupplierID    *uuid.UUID
	BatchCode     string
	ManufactureDate *time.Time
	ExpiryDate    *time.Time
	ReceivedDate  time.Time
	ReceivedQty   decimal.Decimal
	AvailableQty  decimal.Decimal
	ReceivedUOMID uuid.UUID
	UnitCost      decimal.Decimal
	LocationID    uuid.UUID
	QualityStatus string
	Status        string
}

// CreateBatch creates a batch and its corresponding OPENING/PURCHASE_GRN
// receipt stock movement, and seeds the stock_balances projection row, all in
// the caller's transaction. This is the entry point used by GRN posting and
// controlled opening-stock workflows (never a bare stock_balances edit).
func CreateBatch(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, b *Batch, movementType, sourceType string, sourceID *uuid.UUID, deviceID, userID *uuid.UUID) error {
	row := tx.QueryRow(ctx, `
		INSERT INTO batches (
			tenant_id, product_id, supplier_id, batch_code, manufacture_date, expiry_date,
			received_date, received_qty, available_qty, received_uom_id, unit_cost, location_id,
			quality_status, status
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$8,$9,$10,$11,$12,'ACTIVE')
		RETURNING id, status
	`, tenantID, b.ProductID, b.SupplierID, b.BatchCode, b.ManufactureDate, b.ExpiryDate,
		b.ReceivedDate, b.ReceivedQty, b.ReceivedUOMID, b.UnitCost, b.LocationID, b.QualityStatus)
	if err := row.Scan(&b.ID, &b.Status); err != nil {
		return err
	}
	b.AvailableQty = b.ReceivedQty

	if err := PostStockMovement(ctx, tx, tenantID, StockMovement{
		ProductID:      b.ProductID,
		BatchID:        &b.ID,
		LocationID:     b.LocationID,
		UOMID:          b.ReceivedUOMID,
		Quantity:       b.ReceivedQty,
		SignedQuantity: b.ReceivedQty,
		MovementType:   movementType,
		SourceType:     sourceType,
		SourceID:       sourceID,
		UnitCost:       &b.UnitCost,
		DeviceID:       deviceID,
		CreatedByUserID: userID,
	}); err != nil {
		return err
	}
	return nil
}

type StockMovement struct {
	ID              uuid.UUID
	ProductID       uuid.UUID
	BatchID         *uuid.UUID
	LocationID      uuid.UUID
	UOMID           uuid.UUID
	Quantity        decimal.Decimal
	SignedQuantity  decimal.Decimal
	MovementType    string
	SourceType      string
	SourceID        *uuid.UUID
	SourceLineID    *uuid.UUID
	UnitCost        *decimal.Decimal
	ReasonCode      *string
	DeviceID        *uuid.UUID
	CreatedByUserID *uuid.UUID
}

// PostStockMovement is the ONLY function that should ever change inventory:
// it appends to the authoritative stock_movements ledger and upserts the
// stock_balances projection to match. Never update stock_balances directly.
func PostStockMovement(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, m StockMovement) error {
	if m.BatchID == nil {
		return errors.New("stock movements must reference a batch")
	}
	_, err := tx.Exec(ctx, `
		INSERT INTO stock_movements (
			tenant_id, product_id, batch_id, location_id, uom_id, quantity, signed_quantity,
			movement_type, source_type, source_id, source_line_id, unit_cost, reason_code,
			device_id, created_by_user_id
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
	`, tenantID, m.ProductID, m.BatchID, m.LocationID, m.UOMID, m.Quantity, m.SignedQuantity,
		m.MovementType, m.SourceType, m.SourceID, m.SourceLineID, m.UnitCost, m.ReasonCode,
		m.DeviceID, m.CreatedByUserID)
	if err != nil {
		return err
	}

	_, err = tx.Exec(ctx, `
		INSERT INTO stock_balances (tenant_id, product_id, batch_id, location_id, uom_id, on_hand_qty)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (tenant_id, product_id, batch_id, location_id, uom_id)
		DO UPDATE SET on_hand_qty = stock_balances.on_hand_qty + EXCLUDED.on_hand_qty, updated_at = now()
	`, tenantID, m.ProductID, m.BatchID, m.LocationID, m.UOMID, m.SignedQuantity)
	if err != nil {
		return err
	}

	// Batch available_qty tracks the same signed delta so FEFO/FIFO allocation
	// (which reads batches.available_qty under FOR UPDATE) stays consistent
	// with the ledger without a second source of truth diverging silently.
	_, err = tx.Exec(ctx, `
		UPDATE batches SET available_qty = available_qty + $2, updated_at = now(),
		       status = CASE WHEN available_qty + $2 <= 0 THEN 'DEPLETED' ELSE status END
		WHERE id = $1
	`, m.BatchID, m.SignedQuantity)
	return err
}

type Allocation struct {
	BatchID  uuid.UUID
	Quantity decimal.Decimal
	UnitCost decimal.Decimal
}

// AllocateForSale selects sellable batches for productID/locationID totalling
// exactly qtyNeeded, using FEFO (soonest expiry first) or FIFO (oldest
// received first) per the tenant's configured policy, and locks the selected
// batch rows FOR UPDATE so concurrent sales on other connections cannot
// oversell the same stock (PRD A12: concurrency & stock reservation).
// Expired/quarantined/rejected/damaged batches are never eligible.
func AllocateForSale(ctx context.Context, tx pgx.Tx, tenantID, productID, locationID uuid.UUID, qtyNeeded decimal.Decimal, policy string) ([]Allocation, error) {
	orderBy := "b.expiry_date ASC NULLS LAST, b.received_date ASC"
	if policy == "FIFO" {
		orderBy = "b.received_date ASC, b.expiry_date ASC NULLS LAST"
	}

	rows, err := tx.Query(ctx, `
		SELECT b.id, b.available_qty, b.unit_cost
		FROM batches b
		WHERE b.product_id = $1
		  AND b.location_id = $2
		  AND b.status = 'ACTIVE'
		  AND b.quality_status = 'ACCEPTED'
		  AND b.available_qty > 0
		  AND (b.expiry_date IS NULL OR b.expiry_date >= CURRENT_DATE)
		ORDER BY `+orderBy+`
		FOR UPDATE
	`, productID, locationID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	remaining := qtyNeeded
	var allocations []Allocation
	for rows.Next() && remaining.GreaterThan(decimal.Zero) {
		var batchID uuid.UUID
		var available, unitCost decimal.Decimal
		if err := rows.Scan(&batchID, &available, &unitCost); err != nil {
			return nil, err
		}
		take := decimal.Min(available, remaining)
		if take.GreaterThan(decimal.Zero) {
			allocations = append(allocations, Allocation{BatchID: batchID, Quantity: take, UnitCost: unitCost})
			remaining = remaining.Sub(take)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if remaining.GreaterThan(decimal.Zero) {
		return nil, ErrInsufficientStock
	}
	return allocations, nil
}

func GetTenantPolicy(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID) (fifoFefoPolicy string, negativeStockAllowed bool, err error) {
	row := tx.QueryRow(ctx, `SELECT fifo_fefo_policy, negative_stock_allowed FROM tenant_settings WHERE tenant_id = $1`, tenantID)
	err = row.Scan(&fifoFefoPolicy, &negativeStockAllowed)
	if errors.Is(err, pgx.ErrNoRows) {
		return "FEFO", false, nil
	}
	return fifoFefoPolicy, negativeStockAllowed, err
}
