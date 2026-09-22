//go:build integration

// Integration tests against a real, migrated PostgreSQL database. Run with:
//
//	go test -tags=integration ./internal/domain/pos/...
//
// Requires DATABASE_URL (app_user) and DATABASE_ADMIN_URL (app_admin).
package pos_test

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
	"github.com/andipatti/feedmate/services/api/internal/domain/customer"
	"github.com/andipatti/feedmate/services/api/internal/domain/inventory"
	"github.com/andipatti/feedmate/services/api/internal/domain/pos"
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
	customerID      uuid.UUID
	deviceID        uuid.UUID
	userID          uuid.UUID
	sellingPrice    decimal.Decimal // per unit, excl. tax
	cgstRate        decimal.Decimal
	sgstRate        decimal.Decimal
	initialQty      decimal.Decimal
}

// seedFixture creates a fully isolated tenant with everything needed to
// finalize a sale: financial year, invoice document series, tax profile,
// location, product, one batch with known stock, and a credit customer.
func seedFixture(t *testing.T, db *dbctx.DB) *fixture {
	t.Helper()
	f := &fixture{
		tenantID:        uuid.New(),
		financialYearID: uuid.New(),
		locationID:      uuid.New(),
		productID:       uuid.New(),
		batchID:         uuid.New(),
		customerID:      uuid.New(),
		deviceID:        uuid.New(),
		userID:          uuid.New(),
		sellingPrice:    decimal.RequireFromString("1200.00"),
		cgstRate:        decimal.RequireFromString("2.5"),
		sgstRate:        decimal.RequireFromString("2.5"),
		initialQty:      decimal.RequireFromString("100"),
	}
	taxProfileID := uuid.New()

	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		ctx := context.Background()
		execs := []struct {
			sql  string
			args []interface{}
		}{
			{`INSERT INTO tenants (id, legal_name, address_line1, city, state_code) VALUES ($1,'POS Test Tenant','1 St','Town','TN')`,
				[]interface{}{f.tenantID}},
			{`INSERT INTO financial_years (id, tenant_id, label, start_date, end_date, status) VALUES ($1,$2,'FYTEST','2026-01-01','2026-12-31','OPEN')`,
				[]interface{}{f.financialYearID, f.tenantID}},
			{`INSERT INTO tenant_settings (tenant_id, active_financial_year_id) VALUES ($1,$2)`,
				[]interface{}{f.tenantID, f.financialYearID}},
			{`INSERT INTO document_series (tenant_id, financial_year_id, document_type, prefix, next_number, padding) VALUES ($1,$2,'INVOICE','TST-',1,4)`,
				[]interface{}{f.tenantID, f.financialYearID}},
			{`INSERT INTO inventory_locations (id, tenant_id, code, name, location_type) VALUES ($1,$2,'LOC1','Test Location','SHOP')`,
				[]interface{}{f.locationID, f.tenantID}},
			{`INSERT INTO tax_profiles (id, tenant_id, code, description, supply_type, cgst_rate, sgst_rate, effective_from) VALUES ($1,$2,'GST5','GST 5%','INTRA_STATE',$3,$4,'2020-01-01')`,
				[]interface{}{taxProfileID, f.tenantID, f.cgstRate, f.sgstRate}},
			{`INSERT INTO products (id, tenant_id, sku, name, default_sale_uom_id, default_purchase_uom_id, base_inventory_uom_id, tax_profile_id, selling_price, batch_required, expiry_required)
			  VALUES ($1,$2,$3,'Test Feed',$4,$4,$5,$6,$7,true,true)`,
				[]interface{}{f.productID, f.tenantID, "SKU-" + uuid.NewString()[:8], uomBag, uomKG, taxProfileID, f.sellingPrice}},
			{`INSERT INTO batches (id, tenant_id, product_id, batch_code, expiry_date, received_date, received_qty, available_qty, received_uom_id, unit_cost, location_id, quality_status, status)
			  VALUES ($1,$2,$3,'B1','2030-01-01','2026-01-01',$4,$4,$5,'1000.00',$6,'ACCEPTED','ACTIVE')`,
				[]interface{}{f.batchID, f.tenantID, f.productID, f.initialQty, uomBag, f.locationID}},
			{`INSERT INTO stock_movements (tenant_id, product_id, batch_id, location_id, uom_id, quantity, signed_quantity, movement_type, source_type)
			  VALUES ($1,$2,$3,$4,$5,$6,$6,'OPENING','OPENING_BALANCE')`,
				[]interface{}{f.tenantID, f.productID, f.batchID, f.locationID, uomBag, f.initialQty}},
			{`INSERT INTO stock_balances (tenant_id, product_id, batch_id, location_id, uom_id, on_hand_qty) VALUES ($1,$2,$3,$4,$5,$6)`,
				[]interface{}{f.tenantID, f.productID, f.batchID, f.locationID, uomBag, f.initialQty}},
			{`INSERT INTO customers (id, tenant_id, customer_code, name, customer_type, status) VALUES ($1,$2,'CUST1','Test Customer','FARMER','ACTIVE')`,
				[]interface{}{f.customerID, f.tenantID}},
			{`INSERT INTO customer_credit_profiles (customer_id, tenant_id, credit_limit) VALUES ($1,$2,'5000.00')`,
				[]interface{}{f.customerID, f.tenantID}},
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

func availableQty(t *testing.T, db *dbctx.DB, f *fixture) decimal.Decimal {
	t.Helper()
	var qty decimal.Decimal
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT available_qty FROM batches WHERE id = $1`, f.batchID).Scan(&qty)
	})
	if err != nil {
		t.Fatalf("read available qty: %v", err)
	}
	return qty
}

func journalBalance(t *testing.T, db *dbctx.DB, invoiceID uuid.UUID) (debit, credit decimal.Decimal) {
	t.Helper()
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `
			SELECT COALESCE(SUM(jl.debit),0), COALESCE(SUM(jl.credit),0)
			FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id = je.id
			WHERE je.source_id = $1
		`, invoiceID).Scan(&debit, &credit)
	})
	if err != nil {
		t.Fatalf("read journal balance: %v", err)
	}
	return debit, credit
}

func TestFinalizeInvoice_CashSale(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	svc := pos.NewService(db)

	// 3 bags * 1200 = 3600 subtotal; 5% GST = 180; grand total 3780.
	req := pos.FinalizeRequest{
		ClientTransactionID: uuid.New(),
		LocationID:          f.locationID,
		Lines:               []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("3")}},
		Tenders:             []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("3780.00")}},
	}

	result, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, req)
	if err != nil {
		t.Fatalf("finalize: %v", err)
	}
	if !result.GrandTotal.Equal(decimal.RequireFromString("3780.00")) {
		t.Fatalf("expected grand total 3780.00, got %s", result.GrandTotal)
	}

	if got := availableQty(t, db, f); !got.Equal(decimal.RequireFromString("97")) {
		t.Fatalf("expected 97 remaining after selling 3 of 100, got %s", got)
	}

	debit, credit := journalBalance(t, db, result.InvoiceID)
	if !debit.Equal(credit) {
		t.Fatalf("journal not balanced: debit=%s credit=%s", debit, credit)
	}
	if !debit.Equal(decimal.RequireFromString("3780.00")) {
		t.Fatalf("expected journal total 3780.00, got debit=%s", debit)
	}

	t.Run("replaying the same client_transaction_id returns the same invoice without double-deducting stock", func(t *testing.T) {
		replay, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, req)
		if err != nil {
			t.Fatalf("replay: %v", err)
		}
		if !replay.Duplicate {
			t.Fatal("expected Duplicate=true on replay")
		}
		if replay.InvoiceID != result.InvoiceID {
			t.Fatalf("expected same invoice id on replay, got %s vs %s", replay.InvoiceID, result.InvoiceID)
		}
		if got := availableQty(t, db, f); !got.Equal(decimal.RequireFromString("97")) {
			t.Fatalf("stock must not be double-deducted on replay, got %s", got)
		}
	})
}

// TestFinalizeInvoice_CashSaleToRealCustomerAppearsInTheirLedger closes a
// real gap reported live: a fully cash/UPI-paid sale to a named customer
// never posted anything to customer_ledger_entries at all (only the
// credit-tendered *portion* of a sale did), so that customer's ledger
// screen silently omitted every cash purchase — a shop owner checking "what
// has this customer bought from me" saw only their credit history, not a
// complete 360° record. A cash sale must now show both the invoice (debit)
// and its immediate payment (credit) — net zero balance impact, same as
// before, but now visible.
func TestFinalizeInvoice_CashSaleToRealCustomerAppearsInTheirLedger(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	svc := pos.NewService(db)

	req := pos.FinalizeRequest{
		ClientTransactionID: uuid.New(),
		LocationID:          f.locationID,
		CustomerID:          &f.customerID,
		Lines:               []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("3")}},
		Tenders:             []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("3780.00")}},
	}
	result, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, req)
	if err != nil {
		t.Fatalf("finalize: %v", err)
	}

	type ledgerRow struct {
		documentType  string
		debit, credit decimal.Decimal
	}
	var rows []ledgerRow
	err = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		r, err := tx.Query(context.Background(), `
			SELECT document_type, debit, credit FROM customer_ledger_entries
			WHERE customer_id = $1 AND document_id = $2 ORDER BY seq
		`, f.customerID, result.InvoiceID)
		if err != nil {
			return err
		}
		defer r.Close()
		for r.Next() {
			var row ledgerRow
			if err := r.Scan(&row.documentType, &row.debit, &row.credit); err != nil {
				return err
			}
			rows = append(rows, row)
		}
		return r.Err()
	})
	if err != nil {
		t.Fatalf("query ledger entries: %v", err)
	}

	if len(rows) != 2 {
		t.Fatalf("expected 2 ledger entries (invoice debit + payment credit) for a cash sale, got %d: %+v", len(rows), rows)
	}
	if rows[0].documentType != "INVOICE" || !rows[0].debit.Equal(decimal.RequireFromString("3780.00")) || !rows[0].credit.IsZero() {
		t.Fatalf("expected first entry to be the full invoice debit, got %+v", rows[0])
	}
	if rows[1].documentType != "INVOICE" || !rows[1].credit.Equal(decimal.RequireFromString("3780.00")) || !rows[1].debit.IsZero() {
		t.Fatalf("expected second entry to be the full payment credit, got %+v", rows[1])
	}

	balance, err := getOutstandingBalance(db, f.customerID)
	if err != nil {
		t.Fatalf("read balance: %v", err)
	}
	if !balance.IsZero() {
		t.Fatalf("a fully cash-paid sale must leave outstanding balance at zero, got %s", balance)
	}
}

func invoiceCustomer(t *testing.T, db *dbctx.DB, invoiceID uuid.UUID) (customerID *uuid.UUID, customerCode, name string) {
	t.Helper()
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		var custID *uuid.UUID
		var custName *string
		if err := tx.QueryRow(context.Background(),
			`SELECT customer_id, customer_name_snapshot FROM sales_invoices WHERE id = $1`, invoiceID).
			Scan(&custID, &custName); err != nil {
			return err
		}
		if custID != nil {
			if err := tx.QueryRow(context.Background(),
				`SELECT customer_code FROM customers WHERE id = $1`, *custID).Scan(&customerCode); err != nil {
				return err
			}
		}
		customerID = custID
		if custName != nil {
			name = *custName
		}
		return nil
	})
	if err != nil {
		t.Fatalf("read invoice customer: %v", err)
	}
	return customerID, customerCode, name
}

// TestFinalizeInvoice_NoCustomerFallsBackToWalkIn covers the requirement
// that a sale can never be billed with no customer attached at all: a cash
// sale with no customer picked must be billed against the tenant's
// "Walking Customer" (auto-created on first use, reused thereafter), while
// a customer explicitly picked is always honored as-is, and a CREDIT
// tender still requires — and never silently substitutes — a real customer.
func TestFinalizeInvoice_NoCustomerFallsBackToWalkIn(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	svc := pos.NewService(db)

	t.Run("a cash sale with no customer is billed to the Walking Customer", func(t *testing.T) {
		req := pos.FinalizeRequest{
			ClientTransactionID: uuid.New(),
			LocationID:          f.locationID,
			Lines:               []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("1")}},
			Tenders:             []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("1260.00")}},
		}
		result, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, req)
		if err != nil {
			t.Fatalf("finalize: %v", err)
		}
		custID, custCode, name := invoiceCustomer(t, db, result.InvoiceID)
		if custID == nil {
			t.Fatal("expected a customer to be attached to the invoice, got none")
		}
		if custCode != customer.WalkInCustomerCode {
			t.Fatalf("expected walk-in customer code %q, got %q", customer.WalkInCustomerCode, custCode)
		}
		if name != "Walking Customer" {
			t.Fatalf("expected customer name snapshot %q, got %q", "Walking Customer", name)
		}
	})

	t.Run("a second customerless cash sale reuses the same Walking Customer, not a duplicate", func(t *testing.T) {
		req := pos.FinalizeRequest{
			ClientTransactionID: uuid.New(),
			LocationID:          f.locationID,
			Lines:               []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("1")}},
			Tenders:             []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("1260.00")}},
		}
		result, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, req)
		if err != nil {
			t.Fatalf("finalize: %v", err)
		}
		custID, _, _ := invoiceCustomer(t, db, result.InvoiceID)
		if custID == nil {
			t.Fatal("expected a customer to be attached to the invoice, got none")
		}

		var walkInCount int
		if err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
			return tx.QueryRow(context.Background(),
				`SELECT COUNT(*) FROM customers WHERE tenant_id = $1 AND customer_code = $2`,
				f.tenantID, customer.WalkInCustomerCode).Scan(&walkInCount)
		}); err != nil {
			t.Fatalf("count walk-in customers: %v", err)
		}
		if walkInCount != 1 {
			t.Fatalf("expected exactly one Walking Customer row for the tenant, got %d", walkInCount)
		}
	})

	t.Run("a customer picked explicitly is always honored, never overridden by the walk-in fallback", func(t *testing.T) {
		req := pos.FinalizeRequest{
			ClientTransactionID: uuid.New(),
			LocationID:          f.locationID,
			CustomerID:          &f.customerID,
			Lines:               []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("1")}},
			Tenders:             []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("1260.00")}},
		}
		result, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, req)
		if err != nil {
			t.Fatalf("finalize: %v", err)
		}
		custID, _, _ := invoiceCustomer(t, db, result.InvoiceID)
		if custID == nil || *custID != f.customerID {
			t.Fatalf("expected the explicitly picked customer %s, got %v", f.customerID, custID)
		}
	})

	t.Run("a CREDIT tender with no customer is still rejected, never silently billed to the walk-in customer", func(t *testing.T) {
		req := pos.FinalizeRequest{
			ClientTransactionID: uuid.New(),
			LocationID:          f.locationID,
			Lines:               []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("1")}},
			Tenders:             []pos.Tender{{Method: "CREDIT", Amount: decimal.RequireFromString("1260.00")}},
		}
		_, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, req)
		if !errors.Is(err, pos.ErrValidation) {
			t.Fatalf("expected ErrValidation for a credit tender with no customer, got %v", err)
		}
	})

	t.Run("a CREDIT tender explicitly against the Walking Customer is rejected, even with an override requested", func(t *testing.T) {
		// The Walking Customer is a shared anonymous bucket — it must never
		// carry credit, and unlike an ordinary credit-limit breach, this
		// rule is not something credit.override can bypass. Resolve the
		// tenant's walk-in customer id the same way a customerless cash
		// sale would (a prior subtest in this file already created it).
		var walkIn uuid.UUID
		err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
			c, err := customer.GetOrCreateWalkIn(context.Background(), tx, f.tenantID)
			if err != nil {
				return err
			}
			walkIn = c.ID
			return nil
		})
		if err != nil {
			t.Fatalf("resolve walk-in customer: %v", err)
		}

		req := pos.FinalizeRequest{
			ClientTransactionID: uuid.New(),
			LocationID:          f.locationID,
			CustomerID:          &walkIn,
			Lines:               []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("1")}},
			Tenders:             []pos.Tender{{Method: "CREDIT", Amount: decimal.RequireFromString("1260.00")}},
			CreditOverride: struct {
				Requested bool
				Reason    string
			}{Requested: true, Reason: "manager approved"},
		}
		_, err = svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, req)
		if !errors.Is(err, pos.ErrValidation) {
			t.Fatalf("expected ErrValidation for a credit sale against the Walking Customer even with override requested, got %v", err)
		}
	})
}

func TestFinalizeInvoice_InsufficientStock(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	svc := pos.NewService(db)

	req := pos.FinalizeRequest{
		ClientTransactionID: uuid.New(),
		LocationID:          f.locationID,
		Lines:               []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("500")}},
		Tenders:             []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("630000.00")}},
	}
	_, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, req)
	if err == nil {
		t.Fatal("expected insufficient stock error")
	}
	if !errors.Is(err, inventory.ErrInsufficientStock) {
		t.Fatalf("expected insufficient stock error, got: %v", err)
	}
	if got := availableQty(t, db, f); !got.Equal(f.initialQty) {
		t.Fatalf("stock must be unchanged after a rejected sale, got %s (expected %s)", got, f.initialQty)
	}
}

func TestFinalizeInvoice_TenderMismatchRejected(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	svc := pos.NewService(db)

	req := pos.FinalizeRequest{
		ClientTransactionID: uuid.New(),
		LocationID:          f.locationID,
		Lines:               []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("1")}},
		Tenders:             []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("100.00")}},
	}
	_, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, req)
	if err == nil {
		t.Fatal("expected tender mismatch error")
	}
}

func TestFinalizeInvoice_CreditLimit(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	svc := pos.NewService(db)

	// 40 bags * 1260 (incl. tax) = 50400, far beyond the 5000 credit limit.
	overLimitReq := pos.FinalizeRequest{
		ClientTransactionID: uuid.New(),
		LocationID:          f.locationID,
		CustomerID:          &f.customerID,
		Lines:               []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("40")}},
		Tenders:             []pos.Tender{{Method: "CREDIT", Amount: decimal.RequireFromString("50400.00")}},
	}

	t.Run("rejected without an explicit override, even though the amount is large", func(t *testing.T) {
		_, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, overLimitReq)
		if err == nil {
			t.Fatal("expected credit limit exceeded error")
		}
	})

	t.Run("succeeds with an explicit reasoned override and leaves an audit trail", func(t *testing.T) {
		reqWithOverride := overLimitReq
		reqWithOverride.ClientTransactionID = uuid.New()
		reqWithOverride.CreditOverride.Requested = true
		reqWithOverride.CreditOverride.Reason = "test override reason"

		result, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, reqWithOverride)
		if err != nil {
			t.Fatalf("finalize with override: %v", err)
		}

		balance, err := getOutstandingBalance(db, f.customerID)
		if err != nil {
			t.Fatalf("read balance: %v", err)
		}
		if !balance.Equal(decimal.RequireFromString("50400.00")) {
			t.Fatalf("expected customer balance 50400.00, got %s", balance)
		}

		var overrideCount int
		err = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
			return tx.QueryRow(context.Background(), `
				SELECT count(*) FROM audit_logs WHERE entity_id = $1 AND action_code = 'CREDIT_OVERRIDE' AND reason = 'test override reason'
			`, result.InvoiceID).Scan(&overrideCount)
		})
		if err != nil {
			t.Fatalf("query audit log: %v", err)
		}
		if overrideCount != 1 {
			t.Fatalf("expected exactly one CREDIT_OVERRIDE audit entry with the reason, got %d", overrideCount)
		}
	})

	t.Run("rejected when override is requested but no reason is given", func(t *testing.T) {
		reqNoReason := overLimitReq
		reqNoReason.ClientTransactionID = uuid.New()
		reqNoReason.CreditOverride.Requested = true
		reqNoReason.CreditOverride.Reason = ""
		_, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, reqNoReason)
		if err == nil {
			t.Fatal("expected validation error when override reason is missing")
		}
	})
}

func getOutstandingBalance(db *dbctx.DB, customerID uuid.UUID) (decimal.Decimal, error) {
	var balance decimal.Decimal
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		var err error
		balance, err = customer.OutstandingBalance(context.Background(), tx, customerID)
		return err
	})
	return balance, err
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

// TestFinalizeInvoice_ConcurrentSalesNeverOversell exercises PRD A12: when two
// devices race to sell the same limited batch concurrently, the server must
// serialize stock allocation so exactly the available quantity is sold across
// both requests combined — never more, and never a negative balance.
func TestFinalizeInvoice_ConcurrentSalesNeverOversell(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	svc := pos.NewService(db)

	// Only 100 available; two concurrent requests each try to buy 60 (120 total).
	// Exactly one should succeed in full, or they should split, but the sum
	// sold must never exceed 100 and the batch must never go negative.
	qtyPerRequest := decimal.RequireFromString("60")
	unitPriceWithTax := decimal.RequireFromString("1260.00") // 1200 + 5% GST
	amount := unitPriceWithTax.Mul(qtyPerRequest)

	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		go func() {
			req := pos.FinalizeRequest{
				ClientTransactionID: uuid.New(),
				LocationID:          f.locationID,
				Lines:               []pos.SaleLine{{ProductID: f.productID, Quantity: qtyPerRequest}},
				Tenders:             []pos.Tender{{Method: "CASH", Amount: amount}},
			}
			_, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, req)
			results <- err
		}()
	}

	successCount := 0
	for i := 0; i < 2; i++ {
		if err := <-results; err == nil {
			successCount++
		} else if !errors.Is(err, inventory.ErrInsufficientStock) {
			t.Fatalf("unexpected error from concurrent sale: %v", err)
		}
	}

	// 100 available / 60 per request: only one of the two can succeed.
	if successCount != 1 {
		t.Fatalf("expected exactly 1 of 2 concurrent 60-unit sales to succeed against 100 available stock, got %d", successCount)
	}

	remaining := availableQty(t, db, f)
	if remaining.LessThan(decimal.Zero) {
		t.Fatalf("stock must never go negative, got %s", remaining)
	}
	if !remaining.Equal(decimal.RequireFromString("40")) {
		t.Fatalf("expected 40 remaining (100 - 60), got %s", remaining)
	}
}

func TestGetInvoiceForReturn(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	svc := pos.NewService(db)

	req := pos.FinalizeRequest{
		ClientTransactionID: uuid.New(),
		LocationID:          f.locationID,
		Lines:               []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("3")}},
		Tenders:             []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("3780.00")}},
	}
	result, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, req)
	if err != nil {
		t.Fatalf("finalize: %v", err)
	}

	found, err := svc.GetInvoiceForReturn(context.Background(), f.tenantID, result.InvoiceNumber)
	if err != nil {
		t.Fatalf("GetInvoiceForReturn: %v", err)
	}
	if found.Header.ID != result.InvoiceID {
		t.Fatalf("expected header id %s, got %s", result.InvoiceID, found.Header.ID)
	}
	if len(found.Lines) != 1 {
		t.Fatalf("expected 1 line, got %d", len(found.Lines))
	}
	line := found.Lines[0]
	if !line.Quantity.Equal(decimal.RequireFromString("3")) {
		t.Fatalf("expected quantity 3, got %s", line.Quantity)
	}
	if !line.AlreadyReturned.Equal(decimal.Zero) {
		t.Fatalf("expected nothing returned yet, got %s", line.AlreadyReturned)
	}

	t.Run("an unknown invoice number is not found", func(t *testing.T) {
		if _, err := svc.GetInvoiceForReturn(context.Background(), f.tenantID, "NO-SUCH-INVOICE"); !errors.Is(err, pos.ErrNotFound) {
			t.Fatalf("expected ErrNotFound, got: %v", err)
		}
	})
}

func TestListInvoices_ReturnsNewestFirstAndFiltersByQuery(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	svc := pos.NewService(db)

	first, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, pos.FinalizeRequest{
		ClientTransactionID: uuid.New(),
		LocationID:          f.locationID,
		Lines:               []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("1")}},
		Tenders:             []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("1260.00")}},
	})
	if err != nil {
		t.Fatalf("finalize first: %v", err)
	}
	second, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, pos.FinalizeRequest{
		ClientTransactionID: uuid.New(),
		LocationID:          f.locationID,
		Lines:               []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("2")}},
		Tenders:             []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("2520.00")}},
	})
	if err != nil {
		t.Fatalf("finalize second: %v", err)
	}

	page, err := svc.ListInvoices(context.Background(), f.tenantID, "", 10, 0)
	if err != nil {
		t.Fatalf("list invoices: %v", err)
	}
	if page.Total != 2 {
		t.Fatalf("expected total 2, got %d", page.Total)
	}
	if len(page.Invoices) != 2 || page.Invoices[0].ID != second.InvoiceID || page.Invoices[1].ID != first.InvoiceID {
		t.Fatalf("expected [second, first] newest-first order, got %+v", page.Invoices)
	}

	byNumber, err := svc.ListInvoices(context.Background(), f.tenantID, first.InvoiceNumber, 10, 0)
	if err != nil {
		t.Fatalf("list by number: %v", err)
	}
	if len(byNumber.Invoices) != 1 || byNumber.Invoices[0].ID != first.InvoiceID {
		t.Fatalf("expected exactly the matching invoice, got %+v", byNumber.Invoices)
	}
}

func TestGetInvoiceDetail_ReturnsLinesAndTenders(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	svc := pos.NewService(db)

	result, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, pos.FinalizeRequest{
		ClientTransactionID: uuid.New(),
		LocationID:          f.locationID,
		Lines:               []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("3")}},
		Tenders:             []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("3780.00")}},
	})
	if err != nil {
		t.Fatalf("finalize: %v", err)
	}

	detail, err := svc.GetInvoiceDetail(context.Background(), f.tenantID, result.InvoiceID)
	if err != nil {
		t.Fatalf("get invoice detail: %v", err)
	}
	if detail.Header.ID != result.InvoiceID {
		t.Fatalf("expected header id %s, got %s", result.InvoiceID, detail.Header.ID)
	}
	if len(detail.Lines) != 1 || !detail.Lines[0].Quantity.Equal(decimal.RequireFromString("3")) {
		t.Fatalf("expected 1 line with quantity 3, got %+v", detail.Lines)
	}
	if len(detail.Tenders) != 1 || detail.Tenders[0].Method != "CASH" || !detail.Tenders[0].Amount.Equal(decimal.RequireFromString("3780.00")) {
		t.Fatalf("expected 1 CASH tender for 3780.00, got %+v", detail.Tenders)
	}
	// PRD GST-compliance requirement: every invoice line must carry its own
	// CGST/SGST tax breakdown for the printed invoice, not just the invoice-
	// level tax_total.
	if len(detail.Lines[0].TaxLines) != 2 {
		t.Fatalf("expected 2 tax components (CGST+SGST) on the line, got %+v", detail.Lines[0].TaxLines)
	}
	taxByType := map[string]decimal.Decimal{}
	for _, tl := range detail.Lines[0].TaxLines {
		taxByType[tl.TaxType] = tl.Amount
	}
	if !taxByType["CGST"].Equal(decimal.RequireFromString("90.00")) || !taxByType["SGST"].Equal(decimal.RequireFromString("90.00")) {
		t.Fatalf("expected CGST/SGST of 90.00 each (2.5%% of 3600 taxable), got %+v", taxByType)
	}
	if detail.Store.LegalName == "" {
		t.Fatalf("expected the invoice detail to embed the tenant's store profile, got empty legal name")
	}

	if _, err := svc.GetInvoiceDetail(context.Background(), f.tenantID, uuid.New()); !errors.Is(err, pos.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a nonexistent invoice, got: %v", err)
	}
}
