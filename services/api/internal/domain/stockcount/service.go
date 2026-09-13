// Package stockcount implements physical stock-take reconciliation (PRD
// 7.8): a cashier walks the shop counting what's actually on the shelf, the
// system compares each count against what stock_balances says should be
// there, and posting the count adjusts inventory to match reality via the
// same ADJUSTMENT movement type every other inventory correction uses
// (never a bare stock_balances edit — see inventory.PostStockMovement's own
// doc comment on why it is the sole function allowed to change inventory).
package stockcount

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/inventory"
)

var (
	ErrValidation = errors.New("validation error")
	ErrNotOpen    = errors.New("stock count is not in progress")
)

type Service struct {
	db *dbctx.DB
}

func NewService(db *dbctx.DB) *Service {
	return &Service{db: db}
}

// StartCount opens a new physical stock take at a location. countMode is
// FULL (every product) or CYCLE (a subset) — purely descriptive; the app
// does not enforce which products get counted, since that decision is made
// physically by whoever walks the shop with a scanner.
func (s *Service) StartCount(ctx context.Context, tenantID, locationID, userID uuid.UUID, countMode string) (uuid.UUID, error) {
	if countMode != "FULL" && countMode != "CYCLE" {
		return uuid.Nil, fmt.Errorf("%w: count_mode must be FULL or CYCLE", ErrValidation)
	}
	var id uuid.UUID
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		id, err = InsertStockCount(ctx, tx, tenantID, locationID, countMode, userID)
		return err
	})
	if err != nil {
		return uuid.Nil, err
	}
	return id, nil
}

// RecordCount logs (or updates, if this product/batch was already scanned
// in this count) one physically-counted line. expected_qty is snapshotted
// from stock_balances at the moment of the scan, locked so a sale racing in
// between the count and the eventual PostCount cannot silently invalidate
// it (see GetOnHandQty's doc comment).
func (s *Service) RecordCount(ctx context.Context, tenantID, stockCountID, productID, batchID uuid.UUID, countedQty decimal.Decimal, reason string) error {
	if countedQty.LessThan(decimal.Zero) {
		return fmt.Errorf("%w: counted quantity cannot be negative", ErrValidation)
	}
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		count, err := GetStockCountByID(ctx, tx, stockCountID)
		if err != nil {
			return err
		}
		if count.Status != "IN_PROGRESS" {
			return fmt.Errorf("%w: current status is %s", ErrNotOpen, count.Status)
		}

		expectedQty, err := GetOnHandQty(ctx, tx, productID, batchID, count.LocationID)
		if err != nil {
			return fmt.Errorf("read on-hand quantity: %w", err)
		}

		existingID, err := FindCountLine(ctx, tx, stockCountID, productID, batchID)
		if err != nil {
			return err
		}
		if existingID != nil {
			return UpdateCountLine(ctx, tx, *existingID, expectedQty, countedQty, reason)
		}
		_, err = InsertCountLine(ctx, tx, tenantID, stockCountID, productID, batchID, expectedQty, countedQty, reason)
		return err
	})
}

// PostCountResult summarizes what posting a count actually changed, for the
// confirmation screen.
type PostCountResult struct {
	LinesAdjusted int
	NetValueDelta decimal.Decimal
}

// PostCount finalizes a stock count: every line with a non-zero variance
// gets a real ADJUSTMENT stock movement posted (bringing stock_balances in
// line with what was physically counted), then the count itself is marked
// POSTED. Lines with zero variance need no movement at all. This is
// irreversible by design — correcting a mistake after posting means running
// a fresh count, the same as every other append-only ledger in this system.
func (s *Service) PostCount(ctx context.Context, tenantID, stockCountID, userID, deviceID uuid.UUID) (*PostCountResult, error) {
	var result PostCountResult
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		count, err := GetStockCountByID(ctx, tx, stockCountID)
		if err != nil {
			return err
		}
		if count.Status != "IN_PROGRESS" {
			return fmt.Errorf("%w: current status is %s", ErrNotOpen, count.Status)
		}

		lines, err := ListCountLines(ctx, tx, stockCountID)
		if err != nil {
			return err
		}

		for _, line := range lines {
			if line.VarianceQty.IsZero() {
				continue
			}
			uomID, unitCost, err := GetBatchUOMAndCost(ctx, tx, line.BatchID)
			if err != nil {
				return fmt.Errorf("load batch %s: %w", line.BatchID, err)
			}
			if err := inventory.PostStockMovement(ctx, tx, tenantID, inventory.StockMovement{
				ProductID: line.ProductID, BatchID: &line.BatchID, LocationID: count.LocationID,
				UOMID: uomID, Quantity: line.VarianceQty.Abs(), SignedQuantity: line.VarianceQty,
				MovementType: "ADJUSTMENT", SourceType: "STOCK_COUNT", SourceID: &stockCountID,
				UnitCost: &unitCost, DeviceID: &deviceID, CreatedByUserID: &userID,
			}); err != nil {
				return fmt.Errorf("post adjustment for product %s: %w", line.ProductID, err)
			}
			result.LinesAdjusted++
			result.NetValueDelta = result.NetValueDelta.Add(line.VarianceQty.Mul(unitCost))
		}

		if err := SetStockCountStatus(ctx, tx, stockCountID, "POSTED", &userID); err != nil {
			return err
		}

		auditPayload := map[string]interface{}{
			"lines_adjusted":  result.LinesAdjusted,
			"net_value_delta": result.NetValueDelta.StringFixed(2),
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO audit_logs (tenant_id, actor_user_id, action_code, entity_type, entity_id, after_json)
			VALUES ($1,$2,'STOCK_COUNT_POSTED','stock_count',$3,$4)
		`, tenantID, userID, stockCountID, auditPayload)
		return err
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

// CancelCount abandons an in-progress count without touching inventory —
// use when a count was started by mistake or interrupted and cannot be
// completed.
func (s *Service) CancelCount(ctx context.Context, tenantID, stockCountID uuid.UUID) error {
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		count, err := GetStockCountByID(ctx, tx, stockCountID)
		if err != nil {
			return err
		}
		if count.Status != "IN_PROGRESS" {
			return fmt.Errorf("%w: current status is %s", ErrNotOpen, count.Status)
		}
		return SetStockCountStatus(ctx, tx, stockCountID, "CANCELLED", nil)
	})
}

func (s *Service) ListBatchesForProduct(ctx context.Context, tenantID, productID, locationID uuid.UUID) ([]BatchOption, error) {
	var batches []BatchOption
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		batches, err = ListBatchesForProduct(ctx, tx, productID, locationID)
		return err
	})
	return batches, err
}

type StockCountListPage struct {
	Counts []StockCountSummary
	Total  int
}

func (s *Service) ListCounts(ctx context.Context, tenantID uuid.UUID, limit, offset int) (*StockCountListPage, error) {
	var page StockCountListPage
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		counts, total, err := ListStockCounts(ctx, tx, limit, offset)
		if err != nil {
			return err
		}
		page.Counts = counts
		page.Total = total
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &page, nil
}

type StockCountDetail struct {
	Count StockCount
	Lines []CountLineDetail
}

func (s *Service) GetCountDetail(ctx context.Context, tenantID, stockCountID uuid.UUID) (*StockCountDetail, error) {
	var detail StockCountDetail
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		count, err := GetStockCountByID(ctx, tx, stockCountID)
		if err != nil {
			return err
		}
		lines, err := ListCountLines(ctx, tx, stockCountID)
		if err != nil {
			return err
		}
		detail.Count = *count
		detail.Lines = lines
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &detail, nil
}
