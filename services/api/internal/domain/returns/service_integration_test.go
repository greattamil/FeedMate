//go:build integration

// Integration tests against a real, migrated PostgreSQL database. Run with:
//   go test -tags=integration ./internal/domain/returns/...
// Requires DATABASE_URL (app_user) and DATABASE_ADMIN_URL (app_admin).
package returns_test

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
	customerID      uuid.UUID
	deviceID        uuid.UUID
	userID          uuid.UUID
	initialQty      decimal.Decimal
}

func seedFixture(t *testing.T, db *dbctx.DB, initialQty string) *fixture {
	t.Helper()
	f := &fixture{
		tenantID: uuid.New(), financialYearID: uuid.New(), locationID: uuid.New(),
		productID: uuid.New(), batchID: uuid.New(), customerID: uuid.New(),
		deviceID: uuid.New(), userID: uuid.New(), initialQty: decimal.RequireFromString(initialQty),
	}
	taxProfileID := uuid.New()

	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		ctx := context.Background()
		execs := []struct {
			sql  string
			args []interface{}
		}{
			{`INSERT INTO tenants (id, legal_name, address_line1, city, state_code) VALUES ($1,'Return Test Tenant','1 St','Town','TN')`,
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
			  VALUES ($1,$2,$3,'B1','2030-01-01','2026-01-01',$4,$4,$5,'1000.00',$6,'ACCEPTED','ACTIVE')`,
				[]interface{}{f.batchID, f.tenantID, f.productID, f.initialQty, uomBag, f.locationID}},
			{`INSERT INTO stock_movements (tenant_id, product_id, batch_id, location_id, uom_id, quantity, signed_quantity, movement_type, source_type)
			  VALUES ($1,$2,$3,$4,$5,$6,$6,'OPENING','OPENING_BALANCE')`,
				[]interface{}{f.tenantID, f.productID, f.batchID, f.locationID, uomBag, f.initialQty}},
			{`INSERT INTO stock_balances (tenant_id, product_id, batch_id, location_id, uom_id, on_hand_qty) VALUES ($1,$2,$3,$4,$5,$6)`,
				[]interface{}{f.tenantID, f.productID, f.batchID, f.locationID, uomBag, f.initialQty}},
			{`INSERT INTO customers (id, tenant_id, customer_code, name, customer_type, status) VALUES ($1,$2,'CUST1','Test Customer','FARMER','ACTIVE')`,
				[]interface{}{f.customerID, f.tenantID}},
			{`INSERT INTO customer_credit_profiles (customer_id, tenant_id, credit_limit) VALUES ($1,$2,'50000.00')`,
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

func batchStatusAndQty(t *testing.T, db *dbctx.DB, batchID uuid.UUID) (string, decimal.Decimal) {
	t.Helper()
	var status string
	var qty decimal.Decimal
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT status, available_qty FROM batches WHERE id = $1`, batchID).Scan(&status, &qty)
	})
	if err != nil {
		t.Fatalf("read batch: %v", err)
	}
	return status, qty
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

func TestPostReturn_FullSellableReturnCashRefund(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db, "100")
	posSvc := pos.NewService(db)
	returnsSvc := returns.NewService(db)

	// Sell 10 bags: 10*1200=12000 + 5% GST = 12600.
	sale, err := posSvc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, pos.FinalizeRequest{
		ClientTransactionID: uuid.New(), LocationID: f.locationID,
		Lines:   []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("10")}},
		Tenders: []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("12600.00")}},
	})
	if err != nil {
		t.Fatalf("finalize sale: %v", err)
	}
	if status, qty := batchStatusAndQty(t, db, f.batchID); status != "ACTIVE" || !qty.Equal(decimal.RequireFromString("90")) {
		t.Fatalf("unexpected batch state after sale: status=%s qty=%s", status, qty)
	}

	lineID := firstLineID(t, db, sale.InvoiceID)

	// Return all 10 bags, sellable condition, cash refund.
	result, err := returnsSvc.PostReturn(context.Background(), f.tenantID, f.deviceID, f.userID, returns.PostReturnRequest{
		OriginalInvoiceID: sale.InvoiceID, Reason: "customer changed mind",
		Lines: []returns.ReturnLineInput{{OriginalLineID: lineID, Quantity: decimal.RequireFromString("10"), ConditionStatus: "SELLABLE"}},
		RefundMethod: "CASH",
	})
	if err != nil {
		t.Fatalf("post return: %v", err)
	}
	if !result.TotalRefund.Equal(decimal.RequireFromString("12600.00")) {
		t.Fatalf("expected full refund of 12600.00, got %s", result.TotalRefund)
	}

	if status, qty := batchStatusAndQty(t, db, f.batchID); status != "ACTIVE" || !qty.Equal(f.initialQty) {
		t.Fatalf("expected stock fully restocked to %s ACTIVE, got status=%s qty=%s", f.initialQty, status, qty)
	}

	debit, credit := journalBalance(t, db, result.ReturnID)
	if !debit.Equal(credit) {
		t.Fatalf("return journal not balanced: debit=%s credit=%s", debit, credit)
	}
	if !debit.Equal(decimal.RequireFromString("12600.00")) {
		t.Fatalf("expected return journal total 12600.00, got %s", debit)
	}
}

// TestPostReturn_CashRefundToRealCustomerAppearsInTheirLedger closes the
// same 360°-visibility gap as the cash-sale fix, on the return side: before
// this, only a CREDIT_NOTE refund ever touched customer_ledger_entries, so
// a customer's ledger silently omitted every cash-refunded return.
func TestPostReturn_CashRefundToRealCustomerAppearsInTheirLedger(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db, "100")
	posSvc := pos.NewService(db)
	returnsSvc := returns.NewService(db)

	sale, err := posSvc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, pos.FinalizeRequest{
		ClientTransactionID: uuid.New(), LocationID: f.locationID, CustomerID: &f.customerID,
		Lines:   []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("10")}},
		Tenders: []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("12600.00")}},
	})
	if err != nil {
		t.Fatalf("finalize sale: %v", err)
	}
	lineID := firstLineID(t, db, sale.InvoiceID)

	result, err := returnsSvc.PostReturn(context.Background(), f.tenantID, f.deviceID, f.userID, returns.PostReturnRequest{
		OriginalInvoiceID: sale.InvoiceID, Reason: "customer changed mind",
		Lines:        []returns.ReturnLineInput{{OriginalLineID: lineID, Quantity: decimal.RequireFromString("10"), ConditionStatus: "SELLABLE"}},
		RefundMethod: "CASH",
	})
	if err != nil {
		t.Fatalf("post return: %v", err)
	}

	type ledgerRow struct {
		documentType  string
		debit, credit decimal.Decimal
	}
	var rows []ledgerRow
	err = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		r, qerr := tx.Query(context.Background(), `
			SELECT document_type, debit, credit FROM customer_ledger_entries
			WHERE customer_id = $1 AND document_id = $2 ORDER BY seq
		`, f.customerID, result.ReturnID)
		if qerr != nil {
			return qerr
		}
		defer r.Close()
		for r.Next() {
			var row ledgerRow
			if serr := r.Scan(&row.documentType, &row.debit, &row.credit); serr != nil {
				return serr
			}
			rows = append(rows, row)
		}
		return r.Err()
	})
	if err != nil {
		t.Fatalf("query ledger entries: %v", err)
	}

	if len(rows) != 2 {
		t.Fatalf("expected 2 ledger entries (return credit + refund debit) for a cash refund, got %d: %+v", len(rows), rows)
	}
	if rows[0].documentType != "RETURN" || !rows[0].credit.Equal(decimal.RequireFromString("12600.00")) || !rows[0].debit.IsZero() {
		t.Fatalf("expected first entry to be the return credit, got %+v", rows[0])
	}
	if rows[1].documentType != "RETURN" || !rows[1].debit.Equal(decimal.RequireFromString("12600.00")) || !rows[1].credit.IsZero() {
		t.Fatalf("expected second entry to be the cash refund debit, got %+v", rows[1])
	}

	balance, err := getBalance(db, f.customerID)
	if err != nil {
		t.Fatalf("read balance: %v", err)
	}
	if !balance.IsZero() {
		t.Fatalf("a cash-refunded return must leave outstanding balance at zero, got %s", balance)
	}
}

func TestPostReturn_PartialReturnThenExceedingRejected(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db, "100")
	posSvc := pos.NewService(db)
	returnsSvc := returns.NewService(db)

	sale, err := posSvc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, pos.FinalizeRequest{
		ClientTransactionID: uuid.New(), LocationID: f.locationID,
		Lines:   []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("10")}},
		Tenders: []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("12600.00")}},
	})
	if err != nil {
		t.Fatalf("finalize sale: %v", err)
	}
	lineID := firstLineID(t, db, sale.InvoiceID)

	// Return 6 of the 10 — should succeed.
	_, err = returnsSvc.PostReturn(context.Background(), f.tenantID, f.deviceID, f.userID, returns.PostReturnRequest{
		OriginalInvoiceID: sale.InvoiceID, Reason: "partial return",
		Lines:        []returns.ReturnLineInput{{OriginalLineID: lineID, Quantity: decimal.RequireFromString("6"), ConditionStatus: "SELLABLE"}},
		RefundMethod: "CASH",
	})
	if err != nil {
		t.Fatalf("first partial return: %v", err)
	}

	// Attempt to return 5 more (only 4 remain eligible: 10 - 6) — must be rejected.
	_, err = returnsSvc.PostReturn(context.Background(), f.tenantID, f.deviceID, f.userID, returns.PostReturnRequest{
		OriginalInvoiceID: sale.InvoiceID, Reason: "over-return attempt",
		Lines:        []returns.ReturnLineInput{{OriginalLineID: lineID, Quantity: decimal.RequireFromString("5"), ConditionStatus: "SELLABLE"}},
		RefundMethod: "CASH",
	})
	if err == nil {
		t.Fatal("expected rejection when returning more than remains eligible")
	}
	if !errors.Is(err, returns.ErrExceedsSoldQuantity) {
		t.Fatalf("expected ErrExceedsSoldQuantity, got: %v", err)
	}

	// Exactly the remaining 4 should still succeed.
	_, err = returnsSvc.PostReturn(context.Background(), f.tenantID, f.deviceID, f.userID, returns.PostReturnRequest{
		OriginalInvoiceID: sale.InvoiceID, Reason: "return remaining",
		Lines:        []returns.ReturnLineInput{{OriginalLineID: lineID, Quantity: decimal.RequireFromString("4"), ConditionStatus: "SELLABLE"}},
		RefundMethod: "CASH",
	})
	if err != nil {
		t.Fatalf("returning exactly the remaining eligible quantity should succeed: %v", err)
	}

	if _, qty := batchStatusAndQty(t, db, f.batchID); !qty.Equal(f.initialQty) {
		t.Fatalf("expected all 10 units restocked (6+4), batch at %s not %s", qty, f.initialQty)
	}
}

func TestPostReturn_DamagedConditionNeverRestocksSellable(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db, "100")
	posSvc := pos.NewService(db)
	returnsSvc := returns.NewService(db)

	sale, err := posSvc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, pos.FinalizeRequest{
		ClientTransactionID: uuid.New(), LocationID: f.locationID,
		Lines:   []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("5")}},
		Tenders: []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("6300.00")}},
	})
	if err != nil {
		t.Fatalf("finalize sale: %v", err)
	}
	lineID := firstLineID(t, db, sale.InvoiceID)

	_, err = returnsSvc.PostReturn(context.Background(), f.tenantID, f.deviceID, f.userID, returns.PostReturnRequest{
		OriginalInvoiceID: sale.InvoiceID, Reason: "bags damaged in transit",
		Lines: []returns.ReturnLineInput{{
			OriginalLineID: lineID, Quantity: decimal.RequireFromString("5"), ConditionStatus: "DAMAGED",
			RestockLocationID: &f.locationID,
		}},
		RefundMethod: "CASH",
	})
	if err != nil {
		t.Fatalf("post damaged return: %v", err)
	}

	// The original (sellable) batch must NOT have gained the returned units back.
	if _, qty := batchStatusAndQty(t, db, f.batchID); !qty.Equal(decimal.RequireFromString("95")) {
		t.Fatalf("damaged returns must not restock the sellable batch, got available_qty=%s (expected 95)", qty)
	}

	var quarantinedCount int
	err = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `
			SELECT count(*) FROM batches WHERE product_id = $1 AND status = 'QUARANTINED' AND quality_status = 'DAMAGED'
		`, f.productID).Scan(&quarantinedCount)
	})
	if err != nil {
		t.Fatalf("query quarantined batch: %v", err)
	}
	if quarantinedCount != 1 {
		t.Fatalf("expected exactly one quarantined DAMAGED batch, got %d", quarantinedCount)
	}
}

func TestPostReturn_CreditNoteReducesCustomerReceivable(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db, "100")
	posSvc := pos.NewService(db)
	returnsSvc := returns.NewService(db)

	sale, err := posSvc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, pos.FinalizeRequest{
		ClientTransactionID: uuid.New(), LocationID: f.locationID, CustomerID: &f.customerID,
		Lines:   []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("10")}},
		Tenders: []pos.Tender{{Method: "CREDIT", Amount: decimal.RequireFromString("12600.00")}},
	})
	if err != nil {
		t.Fatalf("finalize credit sale: %v", err)
	}

	balanceBefore, _ := getBalance(db, f.customerID)
	if !balanceBefore.Equal(decimal.RequireFromString("12600.00")) {
		t.Fatalf("expected receivable 12600.00 after credit sale, got %s", balanceBefore)
	}

	lineID := firstLineID(t, db, sale.InvoiceID)
	_, err = returnsSvc.PostReturn(context.Background(), f.tenantID, f.deviceID, f.userID, returns.PostReturnRequest{
		OriginalInvoiceID: sale.InvoiceID, Reason: "return against credit sale",
		Lines:        []returns.ReturnLineInput{{OriginalLineID: lineID, Quantity: decimal.RequireFromString("10"), ConditionStatus: "SELLABLE"}},
		RefundMethod: "CREDIT_NOTE",
	})
	if err != nil {
		t.Fatalf("post credit-note return: %v", err)
	}

	balanceAfter, _ := getBalance(db, f.customerID)
	if !balanceAfter.IsZero() {
		t.Fatalf("expected receivable to be fully cleared by credit note, got %s", balanceAfter)
	}
}

func getBalance(db *dbctx.DB, customerID uuid.UUID) (decimal.Decimal, error) {
	var balance decimal.Decimal
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		var err error
		balance, err = customer.OutstandingBalance(context.Background(), tx, customerID)
		return err
	})
	return balance, err
}

func TestPostReturn_DepletedBatchReactivatesOnRestock(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db, "5") // small batch, easy to fully deplete
	posSvc := pos.NewService(db)
	returnsSvc := returns.NewService(db)

	sale, err := posSvc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, pos.FinalizeRequest{
		ClientTransactionID: uuid.New(), LocationID: f.locationID,
		Lines:   []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("5")}},
		Tenders: []pos.Tender{{Method: "CASH", Amount: decimal.RequireFromString("6300.00")}},
	})
	if err != nil {
		t.Fatalf("finalize sale: %v", err)
	}
	if status, qty := batchStatusAndQty(t, db, f.batchID); status != "DEPLETED" || !qty.IsZero() {
		t.Fatalf("expected batch DEPLETED with 0 qty after selling all stock, got status=%s qty=%s", status, qty)
	}

	lineID := firstLineID(t, db, sale.InvoiceID)
	_, err = returnsSvc.PostReturn(context.Background(), f.tenantID, f.deviceID, f.userID, returns.PostReturnRequest{
		OriginalInvoiceID: sale.InvoiceID, Reason: "return to depleted batch",
		Lines:        []returns.ReturnLineInput{{OriginalLineID: lineID, Quantity: decimal.RequireFromString("2"), ConditionStatus: "SELLABLE"}},
		RefundMethod: "CASH",
	})
	if err != nil {
		t.Fatalf("post return: %v", err)
	}

	if status, qty := batchStatusAndQty(t, db, f.batchID); status != "ACTIVE" || !qty.Equal(decimal.RequireFromString("2")) {
		t.Fatalf("expected batch reactivated to ACTIVE with qty 2, got status=%s qty=%s", status, qty)
	}
}
