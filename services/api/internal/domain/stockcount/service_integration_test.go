//go:build integration

// Integration tests against a real, migrated PostgreSQL database. Run with:
//   go test -tags=integration ./internal/domain/stockcount/...
// Requires DATABASE_URL (app_user) and DATABASE_ADMIN_URL (app_admin).
package stockcount_test

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/procurement"
	"github.com/andipatti/feedmate/services/api/internal/domain/stockcount"
)

func mustEnv(t *testing.T, key string) string {
	t.Helper()
	v := os.Getenv(key)
	if v == "" {
		t.Skipf("%s not set; skipping integration test", key)
	}
	return v
}

func connectTest(t *testing.T) *dbctx.DB {
	t.Helper()
	dsn := mustEnv(t, "DATABASE_URL")
	adminDSN := mustEnv(t, "DATABASE_ADMIN_URL")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	db, err := dbctx.Connect(ctx, dsn, adminDSN)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	return db
}

var uomBag = uuid.MustParse("00000000-0000-0000-0000-000000000104")
var uomKG = uuid.MustParse("00000000-0000-0000-0000-000000000101")

type fixture struct {
	tenantID        uuid.UUID
	financialYearID uuid.UUID
	locationID      uuid.UUID
	productID       uuid.UUID
	supplierID      uuid.UUID
	deviceID        uuid.UUID
	userID          uuid.UUID
}

// seedFixture provisions a tenant with 20 bags of real, receipted stock (via
// a real GRN post, not a raw insert) so a count's "expected" figure reflects
// exactly what the rest of this system would compute, not a hand-crafted
// stub.
func seedFixture(t *testing.T, db *dbctx.DB) *fixture {
	t.Helper()
	f := &fixture{
		tenantID: uuid.New(), financialYearID: uuid.New(), locationID: uuid.New(),
		productID: uuid.New(), supplierID: uuid.New(), deviceID: uuid.New(), userID: uuid.New(),
	}
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		ctx := context.Background()
		execs := []struct {
			sql  string
			args []interface{}
		}{
			{`INSERT INTO tenants (id, legal_name, address_line1, city, state_code) VALUES ($1,'StockCount Test Tenant','1 St','Town','TN')`,
				[]interface{}{f.tenantID}},
			{`INSERT INTO tenant_settings (tenant_id, tare_default_max_pct) VALUES ($1, '5.0')`,
				[]interface{}{f.tenantID}},
			{`INSERT INTO financial_years (id, tenant_id, label, start_date, end_date, status) VALUES ($1,$2,'FYTEST','2026-01-01','2026-12-31','OPEN')`,
				[]interface{}{f.financialYearID, f.tenantID}},
			{`UPDATE tenant_settings SET active_financial_year_id = $2 WHERE tenant_id = $1`,
				[]interface{}{f.tenantID, f.financialYearID}},
			{`INSERT INTO document_series (tenant_id, financial_year_id, document_type, prefix, next_number, padding) VALUES ($1,$2,'GRN','GRN-',1,4)`,
				[]interface{}{f.tenantID, f.financialYearID}},
			{`INSERT INTO inventory_locations (id, tenant_id, code, name, location_type) VALUES ($1,$2,'LOC1','Test Location','GODOWN')`,
				[]interface{}{f.locationID, f.tenantID}},
			{`INSERT INTO products (id, tenant_id, sku, name, default_sale_uom_id, default_purchase_uom_id, base_inventory_uom_id, batch_required, expiry_required)
			  VALUES ($1,$2,$3,'Test Feed',$4,$4,$5,true,true)`,
				[]interface{}{f.productID, f.tenantID, "SKU-" + uuid.NewString()[:8], uomBag, uomKG}},
			{`INSERT INTO suppliers (id, tenant_id, supplier_code, legal_name, status) VALUES ($1,$2,'SUP1','Test Supplier','ACTIVE')`,
				[]interface{}{f.supplierID, f.tenantID}},
			{`INSERT INTO devices (id, tenant_id, device_uuid, display_name, platform, status) VALUES ($1,$2,$3,'Test Device','ANDROID','ACTIVE')`,
				[]interface{}{f.deviceID, f.tenantID, uuid.New()}},
		}
		for _, e := range execs {
			if _, err := tx.Exec(ctx, e.sql, e.args...); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("seed fixture: %v", err)
	}
	t.Cleanup(func() {
		_ = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
			_, err := tx.Exec(context.Background(), `DELETE FROM tenants WHERE id = $1`, f.tenantID)
			return err
		})
	})

	procSvc := procurement.NewService(db)
	if _, err := procSvc.PostGRN(context.Background(), f.tenantID, f.deviceID, f.userID, procurement.PostGRNRequest{
		SupplierID: f.supplierID,
		Lines: []procurement.GRNLineInput{{
			ProductID: f.productID, BatchCode: "SC-BATCH-1", ReceivedQty: decimal.RequireFromString("20"),
			UOMID: uomBag, LocationID: f.locationID, UnitCost: decimal.RequireFromString("1000.00"),
			QualityStatus: "ACCEPTED",
		}},
	}); err != nil {
		t.Fatalf("seed opening stock via GRN: %v", err)
	}

	return f
}

func getBatchID(t *testing.T, db *dbctx.DB, productID uuid.UUID) uuid.UUID {
	t.Helper()
	var batchID uuid.UUID
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT id FROM batches WHERE product_id = $1`, productID).Scan(&batchID)
	})
	if err != nil {
		t.Fatalf("look up batch id: %v", err)
	}
	return batchID
}

func onHandQty(t *testing.T, db *dbctx.DB, productID, batchID uuid.UUID) decimal.Decimal {
	t.Helper()
	var qty decimal.Decimal
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT COALESCE(on_hand_qty,0) FROM stock_balances WHERE product_id = $1 AND batch_id = $2`, productID, batchID).Scan(&qty)
	})
	if err != nil {
		t.Fatalf("read on-hand qty: %v", err)
	}
	return qty
}

func TestStockCount_ShortageIsAdjustedDownOnPost(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	batchID := getBatchID(t, db, f.productID)
	svc := stockcount.NewService(db)

	countID, err := svc.StartCount(context.Background(), f.tenantID, f.locationID, f.userID, "CYCLE")
	if err != nil {
		t.Fatalf("start count: %v", err)
	}

	// 20 bags on the books, but only 18 physically found — a shortage of 2.
	if err := svc.RecordCount(context.Background(), f.tenantID, countID, f.productID, batchID, decimal.RequireFromString("18"), "Two bags missing"); err != nil {
		t.Fatalf("record count: %v", err)
	}

	detail, err := svc.GetCountDetail(context.Background(), f.tenantID, countID)
	if err != nil {
		t.Fatalf("get count detail: %v", err)
	}
	if len(detail.Lines) != 1 {
		t.Fatalf("expected 1 line, got %d", len(detail.Lines))
	}
	line := detail.Lines[0]
	if !line.ExpectedQty.Equal(decimal.RequireFromString("20")) {
		t.Fatalf("expected expected_qty 20, got %s", line.ExpectedQty)
	}
	if !line.VarianceQty.Equal(decimal.RequireFromString("-2")) {
		t.Fatalf("expected variance -2, got %s", line.VarianceQty)
	}

	result, err := svc.PostCount(context.Background(), f.tenantID, countID, f.userID, f.deviceID)
	if err != nil {
		t.Fatalf("post count: %v", err)
	}
	if result.LinesAdjusted != 1 {
		t.Fatalf("expected 1 line adjusted, got %d", result.LinesAdjusted)
	}
	if !result.NetValueDelta.Equal(decimal.RequireFromString("-2000.00")) {
		t.Fatalf("expected net value delta -2000.00 (2 bags * 1000), got %s", result.NetValueDelta)
	}

	if got := onHandQty(t, db, f.productID, batchID); !got.Equal(decimal.RequireFromString("18")) {
		t.Fatalf("expected on-hand qty to drop to 18 after posting, got %s", got)
	}

	// A posted count can never be recorded against or posted again.
	if err := svc.RecordCount(context.Background(), f.tenantID, countID, f.productID, batchID, decimal.RequireFromString("18"), ""); !errors.Is(err, stockcount.ErrNotOpen) {
		t.Fatalf("expected ErrNotOpen for recording against a posted count, got: %v", err)
	}
	if _, err := svc.PostCount(context.Background(), f.tenantID, countID, f.userID, f.deviceID); !errors.Is(err, stockcount.ErrNotOpen) {
		t.Fatalf("expected ErrNotOpen for posting an already-posted count, got: %v", err)
	}
}

func TestStockCount_ZeroVarianceLinesNeedNoAdjustment(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	batchID := getBatchID(t, db, f.productID)
	svc := stockcount.NewService(db)

	countID, err := svc.StartCount(context.Background(), f.tenantID, f.locationID, f.userID, "FULL")
	if err != nil {
		t.Fatalf("start count: %v", err)
	}

	// Exactly matches the books — no variance.
	if err := svc.RecordCount(context.Background(), f.tenantID, countID, f.productID, batchID, decimal.RequireFromString("20"), ""); err != nil {
		t.Fatalf("record count: %v", err)
	}

	result, err := svc.PostCount(context.Background(), f.tenantID, countID, f.userID, f.deviceID)
	if err != nil {
		t.Fatalf("post count: %v", err)
	}
	if result.LinesAdjusted != 0 {
		t.Fatalf("expected 0 lines adjusted for an exact match, got %d", result.LinesAdjusted)
	}
	if got := onHandQty(t, db, f.productID, batchID); !got.Equal(decimal.RequireFromString("20")) {
		t.Fatalf("expected on-hand qty to stay at 20, got %s", got)
	}
}

func TestStockCount_RescanningUpdatesTheSameLineInPlace(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	batchID := getBatchID(t, db, f.productID)
	svc := stockcount.NewService(db)

	countID, err := svc.StartCount(context.Background(), f.tenantID, f.locationID, f.userID, "CYCLE")
	if err != nil {
		t.Fatalf("start count: %v", err)
	}

	if err := svc.RecordCount(context.Background(), f.tenantID, countID, f.productID, batchID, decimal.RequireFromString("15"), "first pass"); err != nil {
		t.Fatalf("first record: %v", err)
	}
	if err := svc.RecordCount(context.Background(), f.tenantID, countID, f.productID, batchID, decimal.RequireFromString("19"), "recount, missed a shelf"); err != nil {
		t.Fatalf("second record: %v", err)
	}

	detail, err := svc.GetCountDetail(context.Background(), f.tenantID, countID)
	if err != nil {
		t.Fatalf("get count detail: %v", err)
	}
	if len(detail.Lines) != 1 {
		t.Fatalf("expected the rescan to update the same line, not add a second one, got %d lines", len(detail.Lines))
	}
	if !detail.Lines[0].CountedQty.Equal(decimal.RequireFromString("19")) {
		t.Fatalf("expected the latest counted_qty (19), got %s", detail.Lines[0].CountedQty)
	}
}

func TestListBatchesForProduct_ReturnsActiveBatchesAtLocation(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	batchID := getBatchID(t, db, f.productID)
	svc := stockcount.NewService(db)

	batches, err := svc.ListBatchesForProduct(context.Background(), f.tenantID, f.productID, f.locationID)
	if err != nil {
		t.Fatalf("list batches: %v", err)
	}
	if len(batches) != 1 || batches[0].ID != batchID || batches[0].BatchCode != "SC-BATCH-1" {
		t.Fatalf("expected exactly the seeded batch, got %+v", batches)
	}
	if !batches[0].AvailableQty.Equal(decimal.RequireFromString("20")) {
		t.Fatalf("expected available_qty 20, got %s", batches[0].AvailableQty)
	}
}

func TestStockCount_ListAndCancel(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	svc := stockcount.NewService(db)

	countID, err := svc.StartCount(context.Background(), f.tenantID, f.locationID, f.userID, "CYCLE")
	if err != nil {
		t.Fatalf("start count: %v", err)
	}

	page, err := svc.ListCounts(context.Background(), f.tenantID, 10, 0)
	if err != nil {
		t.Fatalf("list counts: %v", err)
	}
	if page.Total != 1 || page.Counts[0].ID != countID || page.Counts[0].Status != "IN_PROGRESS" {
		t.Fatalf("expected exactly the in-progress count, got %+v", page.Counts)
	}

	if err := svc.CancelCount(context.Background(), f.tenantID, countID); err != nil {
		t.Fatalf("cancel count: %v", err)
	}

	detail, err := svc.GetCountDetail(context.Background(), f.tenantID, countID)
	if err != nil {
		t.Fatalf("get count detail: %v", err)
	}
	if detail.Count.Status != "CANCELLED" {
		t.Fatalf("expected CANCELLED status, got %s", detail.Count.Status)
	}

	if err := svc.CancelCount(context.Background(), f.tenantID, countID); !errors.Is(err, stockcount.ErrNotOpen) {
		t.Fatalf("expected ErrNotOpen for cancelling an already-cancelled count, got: %v", err)
	}

	if _, err := svc.StartCount(context.Background(), f.tenantID, f.locationID, f.userID, "INVALID"); !errors.Is(err, stockcount.ErrValidation) {
		t.Fatalf("expected ErrValidation for an invalid count_mode, got: %v", err)
	}
}
