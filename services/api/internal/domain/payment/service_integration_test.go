//go:build integration

// Integration tests against a real, migrated PostgreSQL database. Run with:
//   go test -tags=integration ./internal/domain/payment/...
// Requires DATABASE_URL (app_user) and DATABASE_ADMIN_URL (app_admin).
package payment_test

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/customer"
	"github.com/andipatti/feedmate/services/api/internal/domain/payment"
	"github.com/andipatti/feedmate/services/api/internal/paymentprovider"
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

type fixture struct {
	tenantID        uuid.UUID
	financialYearID uuid.UUID
	customerID      uuid.UUID
}

func seedFixture(t *testing.T, db *dbctx.DB) *fixture {
	t.Helper()
	f := &fixture{tenantID: uuid.New(), financialYearID: uuid.New(), customerID: uuid.New()}
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		ctx := context.Background()
		execs := []struct {
			sql  string
			args []interface{}
		}{
			{`INSERT INTO tenants (id, legal_name, address_line1, city, state_code) VALUES ($1,'Payment Test Tenant','1 St','Town','TN')`,
				[]interface{}{f.tenantID}},
			{`INSERT INTO financial_years (id, tenant_id, label, start_date, end_date, status) VALUES ($1,$2,'FYTEST','2026-01-01','2026-12-31','OPEN')`,
				[]interface{}{f.financialYearID, f.tenantID}},
			{`INSERT INTO tenant_settings (tenant_id, active_financial_year_id) VALUES ($1,$2)`,
				[]interface{}{f.tenantID, f.financialYearID}},
			{`INSERT INTO customers (id, tenant_id, customer_code, name, customer_type, status) VALUES ($1,$2,'CUST1','Test Customer','FARMER','ACTIVE')`,
				[]interface{}{f.customerID, f.tenantID}},
			{`INSERT INTO customer_credit_profiles (customer_id, tenant_id, credit_limit) VALUES ($1,$2,'50000.00')`,
				[]interface{}{f.customerID, f.tenantID}},
			// Seed an existing receivable so the receipt has something to reduce.
			{`INSERT INTO customer_ledger_entries (tenant_id, customer_id, document_type, document_id, debit, credit, description)
			  VALUES ($1,$2,'OPENING_BALANCE',$3,'5000.00','0.00','Opening balance')`,
				[]interface{}{f.tenantID, f.customerID, uuid.New()}},
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

func buildWebhookPayload(t *testing.T, eventID, orderRef, providerPaymentID, status string, amountRupees decimal.Decimal) []byte {
	t.Helper()
	payload := paymentprovider.SandboxWebhookPayload{
		EventID: eventID, EventType: "payment.captured", OrderReference: orderRef,
		ProviderPaymentID: providerPaymentID, Status: status,
		AmountPaise: amountRupees.Mul(decimal.NewFromInt(100)).IntPart(),
	}
	b, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	return b
}

func TestPaymentWebhook_SuccessCreditsCustomerLedger(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	sandbox := paymentprovider.NewSandboxProvider("test-secret")
	svc := payment.NewService(db, sandbox)

	amount := decimal.RequireFromString("2000.00")
	intentResult, err := svc.CreateReceiptIntent(context.Background(), f.tenantID, payment.CreateReceiptIntentRequest{
		CustomerID: f.customerID, Amount: amount, IdempotencyKey: uuid.NewString(),
	})
	if err != nil {
		t.Fatalf("create receipt intent: %v", err)
	}

	balanceBefore := getBalance(t, db, f.customerID)
	if !balanceBefore.Equal(decimal.RequireFromString("5000.00")) {
		t.Fatalf("expected opening balance 5000.00, got %s", balanceBefore)
	}

	// Extract the sandbox order reference the intent actually used, by
	// reading it back via the QR payload's tr= parameter isn't reliable, so
	// fetch it from the DB directly for the test.
	orderRef := getOrderReference(t, db, intentResult.IntentID)

	payload := buildWebhookPayload(t, "evt_"+uuid.NewString(), orderRef, "pay_"+uuid.NewString(), "SUCCESS", amount)
	signature := sandbox.SignPayload(payload)

	if err := svc.ProcessWebhook(context.Background(), payload, signature); err != nil {
		t.Fatalf("process webhook: %v", err)
	}

	balanceAfter := getBalance(t, db, f.customerID)
	if !balanceAfter.Equal(decimal.RequireFromString("3000.00")) {
		t.Fatalf("expected balance reduced to 3000.00 (5000-2000), got %s", balanceAfter)
	}

	status, err := svc.GetIntentStatus(context.Background(), f.tenantID, intentResult.IntentID)
	if err != nil {
		t.Fatalf("get intent status: %v", err)
	}
	if status != "SUCCESS" {
		t.Fatalf("expected intent status SUCCESS, got %s", status)
	}
}

func TestPaymentWebhook_InvalidSignatureRejectedWithNoSideEffects(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	sandbox := paymentprovider.NewSandboxProvider("test-secret")
	svc := payment.NewService(db, sandbox)

	amount := decimal.RequireFromString("2000.00")
	intentResult, err := svc.CreateReceiptIntent(context.Background(), f.tenantID, payment.CreateReceiptIntentRequest{
		CustomerID: f.customerID, Amount: amount, IdempotencyKey: uuid.NewString(),
	})
	if err != nil {
		t.Fatalf("create receipt intent: %v", err)
	}
	orderRef := getOrderReference(t, db, intentResult.IntentID)

	payload := buildWebhookPayload(t, "evt_"+uuid.NewString(), orderRef, "pay_"+uuid.NewString(), "SUCCESS", amount)
	wrongSignature := "0000000000000000000000000000000000000000000000000000000000000000"

	err = svc.ProcessWebhook(context.Background(), payload, wrongSignature)
	if !errors.Is(err, payment.ErrInvalidSignature) {
		t.Fatalf("expected ErrInvalidSignature, got: %v", err)
	}

	balance := getBalance(t, db, f.customerID)
	if !balance.Equal(decimal.RequireFromString("5000.00")) {
		t.Fatalf("balance must be untouched after a forged webhook, got %s", balance)
	}
}

func TestPaymentWebhook_DuplicateEventHasNoSecondSideEffect(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	sandbox := paymentprovider.NewSandboxProvider("test-secret")
	svc := payment.NewService(db, sandbox)

	amount := decimal.RequireFromString("2000.00")
	intentResult, err := svc.CreateReceiptIntent(context.Background(), f.tenantID, payment.CreateReceiptIntentRequest{
		CustomerID: f.customerID, Amount: amount, IdempotencyKey: uuid.NewString(),
	})
	if err != nil {
		t.Fatalf("create receipt intent: %v", err)
	}
	orderRef := getOrderReference(t, db, intentResult.IntentID)

	eventID := "evt_" + uuid.NewString()
	payload := buildWebhookPayload(t, eventID, orderRef, "pay_"+uuid.NewString(), "SUCCESS", amount)
	signature := sandbox.SignPayload(payload)

	if err := svc.ProcessWebhook(context.Background(), payload, signature); err != nil {
		t.Fatalf("first webhook delivery: %v", err)
	}
	balanceAfterFirst := getBalance(t, db, f.customerID)

	// Redeliver the exact same event (real gateways do this routinely).
	if err := svc.ProcessWebhook(context.Background(), payload, signature); err != nil {
		t.Fatalf("duplicate webhook delivery should be a silent no-op, got error: %v", err)
	}
	balanceAfterDuplicate := getBalance(t, db, f.customerID)

	if !balanceAfterFirst.Equal(balanceAfterDuplicate) {
		t.Fatalf("duplicate webhook must have zero additional financial effect: after first=%s after duplicate=%s", balanceAfterFirst, balanceAfterDuplicate)
	}
	if !balanceAfterDuplicate.Equal(decimal.RequireFromString("3000.00")) {
		t.Fatalf("expected exactly one 2000.00 credit applied, got balance %s", balanceAfterDuplicate)
	}
}

func TestPaymentWebhook_AmountMismatchRejected(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	sandbox := paymentprovider.NewSandboxProvider("test-secret")
	svc := payment.NewService(db, sandbox)

	intentResult, err := svc.CreateReceiptIntent(context.Background(), f.tenantID, payment.CreateReceiptIntentRequest{
		CustomerID: f.customerID, Amount: decimal.RequireFromString("2000.00"), IdempotencyKey: uuid.NewString(),
	})
	if err != nil {
		t.Fatalf("create receipt intent: %v", err)
	}
	orderRef := getOrderReference(t, db, intentResult.IntentID)

	// Provider reports a different (lower) amount than the intent expected.
	payload := buildWebhookPayload(t, "evt_"+uuid.NewString(), orderRef, "pay_"+uuid.NewString(), "SUCCESS", decimal.RequireFromString("1.00"))
	signature := sandbox.SignPayload(payload)

	err = svc.ProcessWebhook(context.Background(), payload, signature)
	if !errors.Is(err, payment.ErrAmountMismatch) {
		t.Fatalf("expected ErrAmountMismatch, got: %v", err)
	}

	balance := getBalance(t, db, f.customerID)
	if !balance.Equal(decimal.RequireFromString("5000.00")) {
		t.Fatalf("balance must be untouched when the webhook amount does not match, got %s", balance)
	}
}

func TestPaymentWebhook_UnknownOrderReferenceRejected(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	sandbox := paymentprovider.NewSandboxProvider("test-secret")
	svc := payment.NewService(db, sandbox)

	payload := buildWebhookPayload(t, "evt_"+uuid.NewString(), "nonexistent_order_ref", "pay_"+uuid.NewString(), "SUCCESS", decimal.RequireFromString("100.00"))
	signature := sandbox.SignPayload(payload)

	err := svc.ProcessWebhook(context.Background(), payload, signature)
	if !errors.Is(err, payment.ErrIntentNotFound) {
		t.Fatalf("expected ErrIntentNotFound, got: %v", err)
	}
}

func getOrderReference(t *testing.T, db *dbctx.DB, intentID uuid.UUID) string {
	t.Helper()
	var ref string
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT provider_order_reference FROM payment_intents WHERE id = $1`, intentID).Scan(&ref)
	})
	if err != nil {
		t.Fatalf("read order reference: %v", err)
	}
	return ref
}
