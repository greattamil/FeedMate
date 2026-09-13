package stockcount

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

var ErrNotFound = errors.New("stock count not found")

type StockCount struct {
	ID               uuid.UUID
	LocationID       uuid.UUID
	CountMode        string // FULL or CYCLE
	StartedAt        time.Time
	CompletedAt      *time.Time
	Status           string // IN_PROGRESS, PENDING_APPROVAL, POSTED, CANCELLED
	CountedByUserID  *uuid.UUID
	ApprovedByUserID *uuid.UUID
}

func InsertStockCount(ctx context.Context, tx pgx.Tx, tenantID, locationID uuid.UUID, countMode string, userID uuid.UUID) (uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO stock_counts (tenant_id, location_id, count_mode, status, counted_by_user_id)
		VALUES ($1,$2,$3,'IN_PROGRESS',$4)
		RETURNING id
	`, tenantID, locationID, countMode, userID).Scan(&id)
	return id, err
}

func GetStockCountByID(ctx context.Context, tx pgx.Tx, id uuid.UUID) (*StockCount, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, location_id, count_mode, started_at, completed_at, status, counted_by_user_id, approved_by_user_id
		FROM stock_counts WHERE id = $1 FOR UPDATE
	`, id)
	var c StockCount
	if err := row.Scan(&c.ID, &c.LocationID, &c.CountMode, &c.StartedAt, &c.CompletedAt, &c.Status, &c.CountedByUserID, &c.ApprovedByUserID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &c, nil
}

// GetOnHandQty locks and returns a product/batch's current on-hand quantity
// at a location — the "expected" figure a count line is compared against.
// Locking here (FOR UPDATE) prevents a sale racing in between the physical
// count and the eventual PostCount adjustment from silently being
// overwritten by a stale expected_qty snapshot.
func GetOnHandQty(ctx context.Context, tx pgx.Tx, productID, batchID, locationID uuid.UUID) (decimal.Decimal, error) {
	var qty decimal.Decimal
	err := tx.QueryRow(ctx, `
		SELECT COALESCE(on_hand_qty, 0) FROM stock_balances
		WHERE product_id = $1 AND batch_id = $2 AND location_id = $3
		FOR UPDATE
	`, productID, batchID, locationID).Scan(&qty)
	if errors.Is(err, pgx.ErrNoRows) {
		return decimal.Zero, nil
	}
	return qty, err
}

// CountLine is one physically-counted product/batch within a stock count.
type CountLine struct {
	ID          uuid.UUID
	ProductID   uuid.UUID
	BatchID     uuid.UUID
	ExpectedQty decimal.Decimal
	CountedQty  decimal.Decimal
	VarianceQty decimal.Decimal
	Reason      *string
}

// FindCountLine looks up an existing line for this product+batch within the
// count, so re-scanning the same item updates it in place instead of
// creating a duplicate row (stock_count_lines has no DB-level unique
// constraint on this combination, so the app enforces it here).
func FindCountLine(ctx context.Context, tx pgx.Tx, stockCountID, productID, batchID uuid.UUID) (*uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `
		SELECT id FROM stock_count_lines WHERE stock_count_id = $1 AND product_id = $2 AND batch_id = $3
	`, stockCountID, productID, batchID).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return &id, err
}

func InsertCountLine(ctx context.Context, tx pgx.Tx, tenantID, stockCountID, productID, batchID uuid.UUID, expectedQty, countedQty decimal.Decimal, reason string) (uuid.UUID, error) {
	var id uuid.UUID
	var reasonPtr *string
	if reason != "" {
		reasonPtr = &reason
	}
	err := tx.QueryRow(ctx, `
		INSERT INTO stock_count_lines (tenant_id, stock_count_id, product_id, batch_id, expected_qty, counted_qty, reason)
		VALUES ($1,$2,$3,$4,$5,$6,$7)
		RETURNING id
	`, tenantID, stockCountID, productID, batchID, expectedQty, countedQty, reasonPtr).Scan(&id)
	return id, err
}

func UpdateCountLine(ctx context.Context, tx pgx.Tx, lineID uuid.UUID, expectedQty, countedQty decimal.Decimal, reason string) error {
	var reasonPtr *string
	if reason != "" {
		reasonPtr = &reason
	}
	_, err := tx.Exec(ctx, `
		UPDATE stock_count_lines SET expected_qty = $2, counted_qty = $3, reason = $4 WHERE id = $1
	`, lineID, expectedQty, countedQty, reasonPtr)
	return err
}

// ListCountLines returns every line of a count plus the product/batch
// display info the review/detail screen needs.
type CountLineDetail struct {
	CountLine
	ProductName string
	SKU         string
	BatchCode   string
}

func ListCountLines(ctx context.Context, tx pgx.Tx, stockCountID uuid.UUID) ([]CountLineDetail, error) {
	rows, err := tx.Query(ctx, `
		SELECT l.id, l.product_id, l.batch_id, l.expected_qty, l.counted_qty, l.variance_qty, l.reason,
		       p.name, p.sku, b.batch_code
		FROM stock_count_lines l
		JOIN products p ON p.id = l.product_id
		JOIN batches b ON b.id = l.batch_id
		WHERE l.stock_count_id = $1
		ORDER BY p.name
	`, stockCountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []CountLineDetail
	for rows.Next() {
		var l CountLineDetail
		if err := rows.Scan(&l.ID, &l.ProductID, &l.BatchID, &l.ExpectedQty, &l.CountedQty, &l.VarianceQty, &l.Reason,
			&l.ProductName, &l.SKU, &l.BatchCode); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

// BatchOption is one active batch of a product at a location — what the
// count-line form needs to let a cashier pick which physical batch they are
// recording a count against.
type BatchOption struct {
	ID           uuid.UUID
	BatchCode    string
	AvailableQty decimal.Decimal
}

func ListBatchesForProduct(ctx context.Context, tx pgx.Tx, productID, locationID uuid.UUID) ([]BatchOption, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, batch_code, available_qty FROM batches
		WHERE product_id = $1 AND location_id = $2 AND status = 'ACTIVE'
		ORDER BY batch_code
	`, productID, locationID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []BatchOption
	for rows.Next() {
		var b BatchOption
		if err := rows.Scan(&b.ID, &b.BatchCode, &b.AvailableQty); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// GetBatchUOMAndCost returns the unit-of-measure and cost a batch's stock is
// tracked in — needed to post a correctly-shaped ADJUSTMENT stock movement
// (see inventory.PostStockMovement) for a count line's variance.
func GetBatchUOMAndCost(ctx context.Context, tx pgx.Tx, batchID uuid.UUID) (uuid.UUID, decimal.Decimal, error) {
	var uomID uuid.UUID
	var unitCost decimal.Decimal
	err := tx.QueryRow(ctx, `SELECT received_uom_id, unit_cost FROM batches WHERE id = $1`, batchID).Scan(&uomID, &unitCost)
	return uomID, unitCost, err
}

func SetStockCountStatus(ctx context.Context, tx pgx.Tx, id uuid.UUID, status string, approvedByUserID *uuid.UUID) error {
	var completedAt *time.Time
	if status == "POSTED" || status == "CANCELLED" {
		now := time.Now()
		completedAt = &now
	}
	tag, err := tx.Exec(ctx, `
		UPDATE stock_counts
		SET status = $2, approved_by_user_id = COALESCE($3, approved_by_user_id),
		    completed_at = COALESCE($4, completed_at)
		WHERE id = $1
	`, id, status, approvedByUserID, completedAt)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// StockCountSummary is one row of the stock-count history browse list.
type StockCountSummary struct {
	StockCount
	LocationName string
}

func ListStockCounts(ctx context.Context, tx pgx.Tx, limit, offset int) ([]StockCountSummary, int, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	var total int
	if err := tx.QueryRow(ctx, `SELECT COUNT(*) FROM stock_counts`).Scan(&total); err != nil {
		return nil, 0, err
	}

	rows, err := tx.Query(ctx, `
		SELECT sc.id, sc.location_id, sc.count_mode, sc.started_at, sc.completed_at, sc.status,
		       sc.counted_by_user_id, sc.approved_by_user_id, loc.name
		FROM stock_counts sc
		JOIN inventory_locations loc ON loc.id = sc.location_id
		ORDER BY sc.started_at DESC
		LIMIT $1 OFFSET $2
	`, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var out []StockCountSummary
	for rows.Next() {
		var s StockCountSummary
		if err := rows.Scan(&s.ID, &s.LocationID, &s.CountMode, &s.StartedAt, &s.CompletedAt, &s.Status,
			&s.CountedByUserID, &s.ApprovedByUserID, &s.LocationName); err != nil {
			return nil, 0, err
		}
		out = append(out, s)
	}
	return out, total, rows.Err()
}
