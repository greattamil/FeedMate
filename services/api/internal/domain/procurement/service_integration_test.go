//go:build integration

// Integration tests against a real, migrated PostgreSQL database. Run with:
//   go test -tags=integration ./internal/domain/procurement/...
// Requires DATABASE_URL (app_user) and DATABASE_ADMIN_URL (app_admin).
package procurement_test

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
	"github.com/andipatti/feedmate/services/api/internal/domain/supplier"
)

func mustEnv(t *testing.T, key string) string {
	t.Helper()
	v := os.Getenv(key)
	if v == "" {
		t.Skipf("%s not set; skipping integration test", key)
	}
	return v
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

func seedFixture(t *testing.T, db *dbctx.DB, tareThresholdPct string) *fixture {
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
			{`INSERT INTO tenants (id, legal_name, address_line1, city, state_code) VALUES ($1,'GRN Test Tenant','1 St','Town','TN')`,
				[]interface{}{f.tenantID}},
			{`INSERT INTO tenant_settings (tenant_id, tare_default_max_pct) VALUES ($1, $2)`,
				[]interface{}{f.tenantID, tareThresholdPct}},
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
	return f
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

func batchAvailableQty(t *testing.T, db *dbctx.DB, productID uuid.UUID) decimal.Decimal {
	t.Helper()
	var qty decimal.Decimal
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT COALESCE(SUM(available_qty),0) FROM batches WHERE product_id = $1 AND status = 'ACTIVE'`, productID).Scan(&qty)
	})
	if err != nil {
		t.Fatalf("read available qty: %v", err)
	}
	return qty
}

func TestPostGRN_CountBasedTareWithinThreshold(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db, "5.0") // 5% max tare
	svc := procurement.NewService(db)

	// 50 bags, gross 2550kg, tare 0.1kg/bag * 50 = 5kg -> net 2545kg.
	// 5kg / 2550kg = 0.196% tare, well within the 5% threshold.
	gross := decimal.RequireFromString("2550")
	tarePerBag := decimal.RequireFromString("0.1")
	bagCount := 50

	result, err := svc.PostGRN(context.Background(), f.tenantID, f.deviceID, f.userID, procurement.PostGRNRequest{
		SupplierID: f.supplierID,
		Lines: []procurement.GRNLineInput{{
			ProductID: f.productID, BatchCode: "B1", ReceivedQty: decimal.RequireFromString("50"),
			UOMID: uomBag, LocationID: f.locationID, UnitCost: decimal.RequireFromString("1000.00"),
			QualityStatus: "ACCEPTED", GrossWeightKg: &gross, TareMethod: "COUNT_BASED",
			BagCount: &bagCount, StandardTarePerBagKg: &tarePerBag,
		}},
	})
	if err != nil {
		t.Fatalf("post GRN: %v", err)
	}
	if result.GRNNumber == "" {
		t.Fatal("expected a GRN number")
	}

	if got := batchAvailableQty(t, db, f.productID); !got.Equal(decimal.RequireFromString("50")) {
		t.Fatalf("expected 50 bags received into sellable stock, got %s", got)
	}

	balance, err := getPayable(db, f.supplierID)
	if err != nil {
		t.Fatalf("read payable: %v", err)
	}
	if !balance.Equal(decimal.RequireFromString("50000.00")) {
		t.Fatalf("expected supplier payable 50000.00 (50 bags * 1000), got %s", balance)
	}
}

func TestPostGRN_TareExceedsThresholdRejectedByDefault(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db, "5.0")
	svc := procurement.NewService(db)

	// 50 bags, gross 2550kg, but an implausibly high tare of 2kg/bag = 100kg
	// tare on 2550kg gross = 3.9% ... let's push it well over 5%: 3kg/bag = 150kg = 5.9%.
	gross := decimal.RequireFromString("2550")
	tarePerBag := decimal.RequireFromString("3.0")
	bagCount := 50

	_, err := svc.PostGRN(context.Background(), f.tenantID, f.deviceID, f.userID, procurement.PostGRNRequest{
		SupplierID: f.supplierID,
		Lines: []procurement.GRNLineInput{{
			ProductID: f.productID, BatchCode: "B1", ReceivedQty: decimal.RequireFromString("50"),
			UOMID: uomBag, LocationID: f.locationID, UnitCost: decimal.RequireFromString("1000.00"),
			QualityStatus: "ACCEPTED", GrossWeightKg: &gross, TareMethod: "COUNT_BASED",
			BagCount: &bagCount, StandardTarePerBagKg: &tarePerBag,
		}},
	})
	if err == nil {
		t.Fatal("expected tare-exceeds-threshold rejection")
	}
	if !errors.Is(err, procurement.ErrTareExceedsThreshold) {
		t.Fatalf("expected ErrTareExceedsThreshold, got: %v", err)
	}

	if got := batchAvailableQty(t, db, f.productID); !got.IsZero() {
		t.Fatalf("no stock should be received when the GRN is rejected, got %s", got)
	}
}

func TestPostGRN_TareOverrideWithReasonSucceedsAndIsAudited(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db, "5.0")
	svc := procurement.NewService(db)

	gross := decimal.RequireFromString("2550")
	tarePerBag := decimal.RequireFromString("3.0")
	bagCount := 50

	req := procurement.PostGRNRequest{
		SupplierID: f.supplierID,
		Lines: []procurement.GRNLineInput{{
			ProductID: f.productID, BatchCode: "B1", ReceivedQty: decimal.RequireFromString("50"),
			UOMID: uomBag, LocationID: f.locationID, UnitCost: decimal.RequireFromString("1000.00"),
			QualityStatus: "ACCEPTED", GrossWeightKg: &gross, TareMethod: "COUNT_BASED",
			BagCount: &bagCount, StandardTarePerBagKg: &tarePerBag,
		}},
	}
	req.TareOverride.Requested = true
	req.TareOverride.Reason = "supplier confirmed unusually wet bags this batch"

	result, err := svc.PostGRN(context.Background(), f.tenantID, f.deviceID, f.userID, req)
	if err != nil {
		t.Fatalf("post GRN with override: %v", err)
	}

	if got := batchAvailableQty(t, db, f.productID); !got.Equal(decimal.RequireFromString("50")) {
		t.Fatalf("expected 50 bags received after override, got %s", got)
	}

	var overrideCount int
	err = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `
			SELECT count(*) FROM audit_logs WHERE entity_id = $1 AND action_code = 'TARE_OVERRIDE' AND reason = $2
		`, result.GRNID, req.TareOverride.Reason).Scan(&overrideCount)
	})
	if err != nil {
		t.Fatalf("query audit log: %v", err)
	}
	if overrideCount != 1 {
		t.Fatalf("expected exactly one TARE_OVERRIDE audit entry with the reason, got %d", overrideCount)
	}
}

func TestPostGRN_NegativeNetWeightRejected(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db, "5.0")
	svc := procurement.NewService(db)

	// Implausible: tare heavier than gross.
	gross := decimal.RequireFromString("100")
	measuredTare := decimal.RequireFromString("150")

	_, err := svc.PostGRN(context.Background(), f.tenantID, f.deviceID, f.userID, procurement.PostGRNRequest{
		SupplierID: f.supplierID,
		Lines: []procurement.GRNLineInput{{
			ProductID: f.productID, BatchCode: "B1", ReceivedQty: decimal.RequireFromString("2"),
			UOMID: uomBag, LocationID: f.locationID, UnitCost: decimal.RequireFromString("1000.00"),
			QualityStatus: "ACCEPTED", GrossWeightKg: &gross, TareMethod: "MEASURED", MeasuredTareKg: &measuredTare,
		}},
	})
	if err == nil {
		t.Fatal("expected negative net weight rejection")
	}
	if !errors.Is(err, procurement.ErrTareNegativeNet) {
		t.Fatalf("expected ErrTareNegativeNet, got: %v", err)
	}
}

func TestPostGRN_RejectedQualityNeverEntersSellableStock(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db, "5.0")
	svc := procurement.NewService(db)

	result, err := svc.PostGRN(context.Background(), f.tenantID, f.deviceID, f.userID, procurement.PostGRNRequest{
		SupplierID: f.supplierID,
		Lines: []procurement.GRNLineInput{{
			ProductID: f.productID, BatchCode: "B1", ReceivedQty: decimal.RequireFromString("10"),
			UOMID: uomBag, LocationID: f.locationID, UnitCost: decimal.RequireFromString("1000.00"),
			QualityStatus: "REJECTED",
		}},
	})
	if err != nil {
		t.Fatalf("post GRN: %v", err)
	}
	if result.GRNNumber == "" {
		t.Fatal("expected GRN to post even for a fully rejected receipt (for traceability)")
	}

	if got := batchAvailableQty(t, db, f.productID); !got.IsZero() {
		t.Fatalf("rejected goods must never become sellable stock, got available_qty=%s", got)
	}

	var batchStatus string
	err = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT status FROM batches WHERE product_id = $1`, f.productID).Scan(&batchStatus)
	})
	if err != nil {
		t.Fatalf("read batch status: %v", err)
	}
	if batchStatus != "QUARANTINED" {
		t.Fatalf("expected rejected batch to be QUARANTINED, got %s", batchStatus)
	}
}

func TestListGRNs_ReturnsNewestFirstAndFiltersByQuery(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db, "5.0")
	svc := procurement.NewService(db)

	first, err := svc.PostGRN(context.Background(), f.tenantID, f.deviceID, f.userID, procurement.PostGRNRequest{
		SupplierID: f.supplierID,
		Lines: []procurement.GRNLineInput{{
			ProductID: f.productID, BatchCode: "HIST-1", ReceivedQty: decimal.RequireFromString("10"),
			UOMID: uomBag, LocationID: f.locationID, UnitCost: decimal.RequireFromString("1000.00"),
			QualityStatus: "ACCEPTED",
		}},
	})
	if err != nil {
		t.Fatalf("post first GRN: %v", err)
	}
	second, err := svc.PostGRN(context.Background(), f.tenantID, f.deviceID, f.userID, procurement.PostGRNRequest{
		SupplierID: f.supplierID,
		Lines: []procurement.GRNLineInput{{
			ProductID: f.productID, BatchCode: "HIST-2", ReceivedQty: decimal.RequireFromString("5"),
			UOMID: uomBag, LocationID: f.locationID, UnitCost: decimal.RequireFromString("1000.00"),
			QualityStatus: "ACCEPTED",
		}},
	})
	if err != nil {
		t.Fatalf("post second GRN: %v", err)
	}

	page, err := svc.ListGRNs(context.Background(), f.tenantID, "", 10, 0)
	if err != nil {
		t.Fatalf("list GRNs: %v", err)
	}
	if page.Total != 2 {
		t.Fatalf("expected total 2, got %d", page.Total)
	}
	if len(page.GRNs) != 2 || page.GRNs[0].Header.ID != second.GRNID || page.GRNs[1].Header.ID != first.GRNID {
		t.Fatalf("expected [second, first] newest-first order, got %+v", page.GRNs)
	}
	if page.GRNs[0].SupplierName == "" {
		t.Fatal("expected the supplier's display name to be joined in")
	}

	byNumber, err := svc.ListGRNs(context.Background(), f.tenantID, first.GRNNumber, 10, 0)
	if err != nil {
		t.Fatalf("list by number: %v", err)
	}
	if len(byNumber.GRNs) != 1 || byNumber.GRNs[0].Header.ID != first.GRNID {
		t.Fatalf("expected exactly the matching GRN, got %+v", byNumber.GRNs)
	}
}

func TestGetGRNDetail_ReturnsLinesWithProductAndBatchInfo(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db, "5.0")
	svc := procurement.NewService(db)

	result, err := svc.PostGRN(context.Background(), f.tenantID, f.deviceID, f.userID, procurement.PostGRNRequest{
		SupplierID: f.supplierID,
		Lines: []procurement.GRNLineInput{{
			ProductID: f.productID, BatchCode: "DETAIL-1", ReceivedQty: decimal.RequireFromString("10"),
			UOMID: uomBag, LocationID: f.locationID, UnitCost: decimal.RequireFromString("1000.00"),
			QualityStatus: "ACCEPTED",
		}},
	})
	if err != nil {
		t.Fatalf("post GRN: %v", err)
	}

	detail, err := svc.GetGRNDetail(context.Background(), f.tenantID, result.GRNID)
	if err != nil {
		t.Fatalf("get GRN detail: %v", err)
	}
	if detail.Header.ID != result.GRNID {
		t.Fatalf("expected header id %s, got %s", result.GRNID, detail.Header.ID)
	}
	if detail.SupplierName == "" {
		t.Fatal("expected supplier name")
	}
	if len(detail.Lines) != 1 {
		t.Fatalf("expected 1 line, got %d", len(detail.Lines))
	}
	line := detail.Lines[0]
	if line.BatchCode != "DETAIL-1" {
		t.Fatalf("expected batch code DETAIL-1, got %q", line.BatchCode)
	}
	if !line.ReceivedQty.Equal(decimal.RequireFromString("10")) {
		t.Fatalf("expected received qty 10, got %s", line.ReceivedQty)
	}
	if line.ProductName == "" || line.SKU == "" {
		t.Fatalf("expected product name and SKU to be joined in, got %+v", line)
	}

	if _, err := svc.GetGRNDetail(context.Background(), f.tenantID, uuid.New()); !errors.Is(err, procurement.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a nonexistent GRN, got: %v", err)
	}
}

func getPayable(db *dbctx.DB, supplierID uuid.UUID) (decimal.Decimal, error) {
	var balance decimal.Decimal
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		var err error
		balance, err = supplier.OutstandingPayable(context.Background(), tx, supplierID)
		return err
	})
	return balance, err
}
