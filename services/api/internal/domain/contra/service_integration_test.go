//go:build integration

// Integration tests against a real, migrated PostgreSQL database. Run with:
//   go test -tags=integration ./internal/domain/contra/...
// Requires DATABASE_URL (app_user) and DATABASE_ADMIN_URL (app_admin).
package contra_test

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/contra"
	"github.com/andipatti/feedmate/services/api/internal/domain/customer"
)

func mustEnv(t *testing.T, key string) string {
	t.Helper()
	v := os.Getenv(key)
	if v == "" {
		t.Skipf("%s not set; skipping integration test", key)
	}
	return v
}

var uomKG = uuid.MustParse("00000000-0000-0000-0000-000000000101")

type fixture struct {
	tenantID        uuid.UUID
	financialYearID uuid.UUID
	locationID      uuid.UUID
	productID       uuid.UUID
	customerID      uuid.UUID
	deviceID        uuid.UUID
	userID          uuid.UUID
}

func seedFixture(t *testing.T, db *dbctx.DB) *fixture {
	t.Helper()
	f := &fixture{
		tenantID: uuid.New(), financialYearID: uuid.New(), locationID: uuid.New(),
		productID: uuid.New(), customerID: uuid.New(), deviceID: uuid.New(), userID: uuid.New(),
	}
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		ctx := context.Background()
		execs := []struct {
			sql  string
			args []interface{}
		}{
			{`INSERT INTO tenants (id, legal_name, address_line1, city, state_code) VALUES ($1,'Contra Test Tenant','1 St','Town','TN')`,
				[]interface{}{f.tenantID}},
			{`INSERT INTO financial_years (id, tenant_id, label, start_date, end_date, status) VALUES ($1,$2,'FYTEST','2026-01-01','2026-12-31','OPEN')`,
				[]interface{}{f.financialYearID, f.tenantID}},
			{`INSERT INTO tenant_settings (tenant_id, active_financial_year_id) VALUES ($1,$2)`,
				[]interface{}{f.tenantID, f.financialYearID}},
			{`INSERT INTO document_series (tenant_id, financial_year_id, document_type, prefix, next_number, padding) VALUES ($1,$2,'CONTRA','CTR-',1,4)`,
				[]interface{}{f.tenantID, f.financialYearID}},
			{`INSERT INTO inventory_locations (id, tenant_id, code, name, location_type) VALUES ($1,$2,'LOC1','Test Location','GODOWN')`,
				[]interface{}{f.locationID, f.tenantID}},
			{`INSERT INTO products (id, tenant_id, sku, name, default_sale_uom_id, default_purchase_uom_id, base_inventory_uom_id, batch_required, expiry_required)
			  VALUES ($1,$2,$3,'Maize (buy-back)',$4,$4,$4,true,false)`,
				[]interface{}{f.productID, f.tenantID, "SKU-" + uuid.NewString()[:8], uomKG}},
			{`INSERT INTO customers (id, tenant_id, customer_code, name, customer_type, status) VALUES ($1,$2,'CUST1','Test Farmer','FARMER','ACTIVE')`,
				[]interface{}{f.customerID, f.tenantID}},
			{`INSERT INTO customer_credit_profiles (customer_id, tenant_id, credit_limit) VALUES ($1,$2,'50000.00')`,
				[]interface{}{f.customerID, f.tenantID}},
			// Existing receivable for the contra to reduce.
			{`INSERT INTO customer_ledger_entries (tenant_id, customer_id, document_type, document_id, debit, credit, description)
			  VALUES ($1,$2,'OPENING_BALANCE',$3,'10000.00','0.00','Opening balance')`,
				[]interface{}{f.tenantID, f.customerID, uuid.New()}},
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

func getBalance(t *testing.T, db *dbctx.DB, customerID uuid.UUID) decimal.Decimal {
	t.Helper()
	var balance decimal.Decimal
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		var err error
		balance, err = customer.OutstandingBalance(context.Background(), tx, customerID)
		return err
	})
	if err != nil {
		t.Fatalf("read balance: %v", err)
	}
	return balance
}

func journalBalance(t *testing.T, db *dbctx.DB, sourceID uuid.UUID) (debit, credit decimal.Decimal) {
	t.Helper()
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `
			SELECT COALESCE(SUM(jl.debit),0), COALESCE(SUM(jl.credit),0)
			FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id = je.id
			WHERE je.source_id = $1
		`, sourceID).Scan(&debit, &credit)
	})
	if err != nil {
		t.Fatalf("read journal balance: %v", err)
	}
	return debit, credit
}

func batchQty(t *testing.T, db *dbctx.DB, productID uuid.UUID) decimal.Decimal {
	t.Helper()
	var qty decimal.Decimal
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT COALESCE(SUM(available_qty),0) FROM batches WHERE product_id = $1 AND status = 'ACTIVE'`, productID).Scan(&qty)
	})
	if err != nil {
		t.Fatalf("read batch qty: %v", err)
	}
	return qty
}

func TestPostContra_ReducesReceivableAndCreatesInventory(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	svc := contra.NewService(db)

	// 100kg maize at 15/kg = 1500 value.
	result, err := svc.PostContra(context.Background(), f.tenantID, f.deviceID, f.userID, contra.PostContraRequest{
		CustomerID: f.customerID,
		Lines: []contra.ContraLineInput{{
			ProductID: f.productID, BatchCode: "MAIZE-B1", Quantity: decimal.RequireFromString("100"),
			UOMID: uomKG, ValuationUnitPrice: decimal.RequireFromString("15.00"),
			QualityStatus: "ACCEPTED", LocationID: f.locationID,
		}},
	})
	if err != nil {
		t.Fatalf("post contra: %v", err)
	}
	if !result.TotalValue.Equal(decimal.RequireFromString("1500.00")) {
		t.Fatalf("expected total value 1500.00, got %s", result.TotalValue)
	}

	balance := getBalance(t, db, f.customerID)
	if !balance.Equal(decimal.RequireFromString("8500.00")) {
		t.Fatalf("expected receivable reduced to 8500.00 (10000-1500), got %s", balance)
	}

	if qty := batchQty(t, db, f.productID); !qty.Equal(decimal.RequireFromString("100")) {
		t.Fatalf("expected 100kg received into sellable stock, got %s", qty)
	}

	debit, credit := journalBalance(t, db, result.ContraID)
	if !debit.Equal(credit) {
		t.Fatalf("contra journal not balanced: debit=%s credit=%s", debit, credit)
	}
	if !debit.Equal(decimal.RequireFromString("1500.00")) {
		t.Fatalf("expected journal total 1500.00, got %s", debit)
	}
}

func TestPostContra_RejectedQualityNeverEntersSellableStock(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	svc := contra.NewService(db)

	_, err := svc.PostContra(context.Background(), f.tenantID, f.deviceID, f.userID, contra.PostContraRequest{
		CustomerID: f.customerID,
		Lines: []contra.ContraLineInput{{
			ProductID: f.productID, BatchCode: "MAIZE-B2", Quantity: decimal.RequireFromString("50"),
			UOMID: uomKG, ValuationUnitPrice: decimal.RequireFromString("15.00"),
			QualityStatus: "REJECTED", LocationID: f.locationID,
		}},
	})
	if err != nil {
		t.Fatalf("post contra: %v", err)
	}

	if qty := batchQty(t, db, f.productID); !qty.IsZero() {
		t.Fatalf("rejected contra intake must not become sellable stock, got %s", qty)
	}
}

func TestPostContra_NegativeValuationRejected(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	svc := contra.NewService(db)

	_, err := svc.PostContra(context.Background(), f.tenantID, f.deviceID, f.userID, contra.PostContraRequest{
		CustomerID: f.customerID,
		Lines: []contra.ContraLineInput{{
			ProductID: f.productID, BatchCode: "MAIZE-B3", Quantity: decimal.RequireFromString("10"),
			UOMID: uomKG, ValuationUnitPrice: decimal.RequireFromString("-5.00"),
			QualityStatus: "ACCEPTED", LocationID: f.locationID,
		}},
	})
	if err == nil {
		t.Fatal("expected negative valuation to be rejected")
	}
}
