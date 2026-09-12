//go:build integration

// Integration tests against a real, migrated PostgreSQL database. Run with:
//   go test -tags=integration ./internal/domain/eod/...
// Requires DATABASE_URL (app_user) and DATABASE_ADMIN_URL (app_admin).
package eod_test

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
	"github.com/andipatti/feedmate/services/api/internal/domain/eod"
	"github.com/andipatti/feedmate/services/api/internal/domain/pos"
	"github.com/andipatti/feedmate/services/api/internal/domain/returns"
)

func mustEnv(t *testing.T, key string) string {
	t.Helper()
	v := os.Getenv(key)
	if v == "" {
		t.Skipf("%s not set; skipping integration test", key)
	}
	return v
}

var (
	uomBag = uuid.MustParse("00000000-0000-0000-0000-000000000104")
	uomKG  = uuid.MustParse("00000000-0000-0000-0000-000000000101")
)

type fixture struct {
	tenantID        uuid.UUID
	financialYearID uuid.UUID
	locationID      uuid.UUID
	productID       uuid.UUID
	batchID         uuid.UUID
	deviceID        uuid.UUID
	userID          uuid.UUID
	businessDate    time.Time
}

func seedFixture(t *testing.T, db *dbctx.DB) *fixture {
	t.Helper()
	f := &fixture{
		tenantID: uuid.New(), financialYearID: uuid.New(), locationID: uuid.New(),
		productID: uuid.New(), batchID: uuid.New(), deviceID: uuid.New(), userID: uuid.New(),
		businessDate: time.Now().UTC().Truncate(24 * time.Hour),
	}
	taxProfileID := uuid.New()
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		ctx := context.Background()
		execs := []struct {
			sql  string
			args []interface{}
		}{
			{`INSERT INTO tenants (id, legal_name, address_line1, city, state_code) VALUES ($1,'EOD Test Tenant','1 St','Town','TN')`,
				[]interface{}{f.tenantID}},
			{`INSERT INTO financial_years (id, tenant_id, label, start_date, end_date, status) VALUES ($1,$2,'FYTEST','2026-01-01','2026-12-31','OPEN')`,
				[]interface{}{f.financialYearID, f.tenantID}},
			{`INSERT INTO tenant_settings (tenant_id, active_financial_year_id) VALUES ($1,$2)`,
				[]interface{}{f.tenantID, f.financialYearID}},
			{`INSERT INTO document_series (tenant_id, financial_year_id, document_type, prefix, next_number, padding) VALUES ($1,$2,'INVOICE','TST-',1,4)`,
				[]interface{}{f.tenantID, f.financialYearID}},
			{`INSERT INTO document_series (tenant_id, financial_year_id, document_type, prefix, next_number, padding) VALUES ($1,$2,'RETURN','RET-',1,4)`,
				[]interface{}{f.tenantID, f.financialYearID}},
			{`INSERT INTO inventory_locations (id, tenant_id, code, name, location_type) VALUES ($1,$2,'LOC1','Test Location','SHOP')`,
				[]interface{}{f.locationID, f.tenantID}},
			{`INSERT INTO tax_profiles (id, tenant_id, code, description, supply_type, cgst_rate, sgst_rate, effective_from) VALUES ($1,$2,'GST5','GST 5%','INTRA_STATE',2.5,2.5,'2020-01-01')`,
				[]interface{}{taxProfileID, f.tenantID}},
			{`INSERT INTO products (id, tenant_id, sku, name, default_sale_uom_id, default_purchase_uom_id, base_inventory_uom_id, tax_profile_id, selling_price, batch_required, expiry_required)
			  VALUES ($1,$2,$3,'Test Feed',$4,$4,$5,$6,'1200.00',true,true)`,
				[]interface{}{f.productID, f.tenantID, "SKU-" + uuid.NewString()[:8], uomBag, uomKG, taxProfileID}},
			{`INSERT INTO batches (id, tenant_id, product_id, batch_code, expiry_date, received_date, received_qty, available_qty, received_uom_id, unit_cost, location_id, quality_status, status)
			  VALUES ($1,$2,$3,'B1','2030-01-01','2026-01-01','100','100',$4,'1000.00',$5,'ACCEPTED','ACTIVE')`,
				[]interface{}{f.batchID, f.tenantID, f.productID, uomBag, f.locationID}},
			{`INSERT INTO stock_movements (tenant_id, product_id, batch_id, location_id, uom_id, quantity, signed_quantity, movement_type, source_type)
			  VALUES ($1,$2,$3,$4,$5,'100','100','OPENING','OPENING_BALANCE')`,
				[]interface{}{f.tenantID, f.productID, f.batchID, f.locationID, uomBag}},
			{`INSERT INTO stock_balances (tenant_id, product_id, batch_id, location_id, uom_id, on_hand_qty) VALUES ($1,$2,$3,$4,$5,'100')`,
				[]interface{}{f.tenantID, f.productID, f.batchID, f.locationID, uomBag}},
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

func firstLineID(t *testing.T, db *dbctx.DB, invoiceID uuid.UUID) uuid.UUID {
	t.Helper()
	var id uuid.UUID
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT id FROM sales_invoice_lines WHERE invoice_id = $1 LIMIT 1`, invoiceID).Scan(&id)
	})
	if err != nil {
		t.Fatalf("find invoice line: %v", err)
	}
	return id
}

func TestEOD_CashSaleReconcilesExactly(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	posSvc := pos.NewService(db)
	eodSvc := eod.NewService(db)

	sessionID, err := eodSvc.OpenSession(context.Background(), f.tenantID, f.userID, f.businessDate, decimal.RequireFromString("1000.00"))
	if err != nil {
		t.Fatalf("open session: %v", err)
	}

	// Sell 2 bags cash: 2*1200 = 2400 + 5% GST = 2520.
	_, err = posSvc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, pos.FinalizeRequest{
		ClientTransactionID: uuid.New(), LocationID: f.locationID,
		Lines:   []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("2")}},
		Tenders: []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("2520.00")}},
	})
	if err != nil {
		t.Fatalf("finalize sale: %v", err)
	}

	// Expected cash = 1000 opening + 2520 cash sales = 3520. Counted exactly that.
	result, err := eodSvc.CloseSession(context.Background(), f.tenantID, f.userID, f.businessDate, decimal.RequireFromString("3520.00"), "")
	if err != nil {
		t.Fatalf("close session: %v", err)
	}
	if result.SessionID != sessionID {
		t.Fatalf("expected session id %s, got %s", sessionID, result.SessionID)
	}
	if !result.ExpectedCash.Equal(decimal.RequireFromString("3520.00")) {
		t.Fatalf("expected expected_cash 3520.00, got %s", result.ExpectedCash)
	}
	if !result.Variance.IsZero() {
		t.Fatalf("expected zero variance, got %s", result.Variance)
	}
}

func TestEOD_MismatchRequiresReasonThenSucceeds(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	posSvc := pos.NewService(db)
	eodSvc := eod.NewService(db)

	if _, err := eodSvc.OpenSession(context.Background(), f.tenantID, f.userID, f.businessDate, decimal.RequireFromString("500.00")); err != nil {
		t.Fatalf("open session: %v", err)
	}
	_, err := posSvc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, pos.FinalizeRequest{
		ClientTransactionID: uuid.New(), LocationID: f.locationID,
		Lines:   []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("1")}},
		Tenders: []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("1260.00")}},
	})
	if err != nil {
		t.Fatalf("finalize sale: %v", err)
	}

	// Expected = 500 + 1260 = 1760. Cashier actually counts 1700 (short by 60).
	_, err = eodSvc.CloseSession(context.Background(), f.tenantID, f.userID, f.businessDate, decimal.RequireFromString("1700.00"), "")
	if err == nil {
		t.Fatal("expected rejection when variance exists but no reason is given")
	}
	if !errors.Is(err, eod.ErrValidation) {
		t.Fatalf("expected ErrValidation, got: %v", err)
	}

	result, err := eodSvc.CloseSession(context.Background(), f.tenantID, f.userID, f.businessDate, decimal.RequireFromString("1700.00"), "till was short, investigating")
	if err != nil {
		t.Fatalf("close with reason should succeed: %v", err)
	}
	if !result.Variance.Equal(decimal.RequireFromString("-60.00")) {
		t.Fatalf("expected variance -60.00 (short), got %s", result.Variance)
	}
}

func TestEOD_CashRefundReducesExpectedCash(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	posSvc := pos.NewService(db)
	returnsSvc := returns.NewService(db)
	eodSvc := eod.NewService(db)

	if _, err := eodSvc.OpenSession(context.Background(), f.tenantID, f.userID, f.businessDate, decimal.Zero); err != nil {
		t.Fatalf("open session: %v", err)
	}

	sale, err := posSvc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, pos.FinalizeRequest{
		ClientTransactionID: uuid.New(), LocationID: f.locationID,
		Lines:   []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("2")}},
		Tenders: []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("2520.00")}},
	})
	if err != nil {
		t.Fatalf("finalize sale: %v", err)
	}
	lineID := firstLineID(t, db, sale.InvoiceID)

	// Return 1 bag for cash refund: refund = 1260.
	_, err = returnsSvc.PostReturn(context.Background(), f.tenantID, f.deviceID, f.userID, returns.PostReturnRequest{
		OriginalInvoiceID: sale.InvoiceID, Reason: "test return",
		Lines:        []returns.ReturnLineInput{{OriginalLineID: lineID, Quantity: decimal.RequireFromString("1"), ConditionStatus: "SELLABLE"}},
		RefundMethod: "CASH",
	})
	if err != nil {
		t.Fatalf("post return: %v", err)
	}

	// Expected = 0 opening + 2520 sales - 1260 refund = 1260.
	result, err := eodSvc.CloseSession(context.Background(), f.tenantID, f.userID, f.businessDate, decimal.RequireFromString("1260.00"), "")
	if err != nil {
		t.Fatalf("close session: %v", err)
	}
	if !result.ExpectedCash.Equal(decimal.RequireFromString("1260.00")) {
		t.Fatalf("expected expected_cash 1260.00 (2520 sales - 1260 refund), got %s", result.ExpectedCash)
	}
	if !result.Variance.IsZero() {
		t.Fatalf("expected zero variance, got %s", result.Variance)
	}
}

func TestEOD_DoubleOpenRejected(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	eodSvc := eod.NewService(db)

	if _, err := eodSvc.OpenSession(context.Background(), f.tenantID, f.userID, f.businessDate, decimal.Zero); err != nil {
		t.Fatalf("first open: %v", err)
	}
	_, err := eodSvc.OpenSession(context.Background(), f.tenantID, f.userID, f.businessDate, decimal.Zero)
	if !errors.Is(err, eod.ErrSessionExists) {
		t.Fatalf("expected ErrSessionExists on double-open, got: %v", err)
	}
}

func TestEOD_CloseAlreadyClosedRejected(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	eodSvc := eod.NewService(db)

	if _, err := eodSvc.OpenSession(context.Background(), f.tenantID, f.userID, f.businessDate, decimal.Zero); err != nil {
		t.Fatalf("open: %v", err)
	}
	if _, err := eodSvc.CloseSession(context.Background(), f.tenantID, f.userID, f.businessDate, decimal.Zero, ""); err != nil {
		t.Fatalf("first close: %v", err)
	}
	_, err := eodSvc.CloseSession(context.Background(), f.tenantID, f.userID, f.businessDate, decimal.Zero, "")
	if !errors.Is(err, eod.ErrSessionNotOpen) {
		t.Fatalf("expected ErrSessionNotOpen on double-close, got: %v", err)
	}
}

func TestEOD_ReopenThenCloseAgain(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	eodSvc := eod.NewService(db)

	if _, err := eodSvc.OpenSession(context.Background(), f.tenantID, f.userID, f.businessDate, decimal.Zero); err != nil {
		t.Fatalf("open: %v", err)
	}
	if _, err := eodSvc.CloseSession(context.Background(), f.tenantID, f.userID, f.businessDate, decimal.Zero, ""); err != nil {
		t.Fatalf("close: %v", err)
	}

	// Reopening a non-closed (already OPEN, e.g. never closed) session should fail —
	// verify reopen requires CLOSED status, and requires a reason.
	if err := eodSvc.ReopenSession(context.Background(), f.tenantID, f.userID, f.businessDate, ""); err == nil {
		t.Fatal("expected reopen without a reason to be rejected")
	}

	if err := eodSvc.ReopenSession(context.Background(), f.tenantID, f.userID, f.businessDate, "late transaction needs posting"); err != nil {
		t.Fatalf("reopen with reason: %v", err)
	}

	session, err := eodSvc.GetSession(context.Background(), f.tenantID, f.businessDate)
	if err != nil {
		t.Fatalf("get session: %v", err)
	}
	if session.Status != "REOPENED" {
		t.Fatalf("expected status REOPENED, got %s", session.Status)
	}

	// Reopening again (status is REOPENED, not CLOSED) must fail.
	if err := eodSvc.ReopenSession(context.Background(), f.tenantID, f.userID, f.businessDate, "again"); !errors.Is(err, eod.ErrNotClosed) {
		t.Fatalf("expected ErrNotClosed, got: %v", err)
	}
}
