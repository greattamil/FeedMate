//go:build integration

package customer_test

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

func seedTenant(t *testing.T, db *dbctx.DB) uuid.UUID {
	t.Helper()
	tenantID := uuid.New()
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(), `INSERT INTO tenants (id, legal_name, address_line1, city, state_code) VALUES ($1,'Customer Test Tenant','1 St','Town','TN')`, tenantID)
		return err
	})
	if err != nil {
		t.Fatalf("seed tenant: %v", err)
	}
	// Cleanup in dependency order rather than a bare tenant DELETE, which
	// silently no-ops under FK constraints without ON DELETE CASCADE (see
	// docs/IMPLEMENTATION_STATUS.md Phase 13's systemic-cleanup finding) —
	// deleting child rows first here actually works instead of leaking.
	t.Cleanup(func() {
		_ = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
			ctx := context.Background()
			for _, stmt := range []string{
				`DELETE FROM customer_ledger_entries WHERE tenant_id = $1`,
				`DELETE FROM customer_credit_profiles WHERE tenant_id = $1`,
				`DELETE FROM customers WHERE tenant_id = $1`,
				`DELETE FROM tenants WHERE id = $1`,
			} {
				if _, err := tx.Exec(ctx, stmt, tenantID); err != nil {
					return err
				}
			}
			return nil
		})
	})
	return tenantID
}

func TestCustomerCreateAndFetch(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := customer.NewService(db)

	creditLimit := decimal.RequireFromString("5000.00")
	created, err := svc.Create(context.Background(), tenantID, customer.CreateInput{
		CustomerCode: "FARM001", Name: "Test Farmer", LocalName: "சோதனை விவசாயி",
		Phone: "9876543210", CustomerType: "FARMER", CreditLimit: &creditLimit,
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if created.Status != "ACTIVE" {
		t.Fatalf("expected newly created customer to be ACTIVE, got %s", created.Status)
	}

	fetched, profile, balance, err := svc.GetByID(context.Background(), tenantID, created.ID)
	if err != nil {
		t.Fatalf("get by id: %v", err)
	}
	if fetched.Name != "Test Farmer" {
		t.Fatalf("expected name 'Test Farmer', got %q", fetched.Name)
	}
	if !profile.CreditLimit.Equal(creditLimit) {
		t.Fatalf("expected credit limit %s, got %s", creditLimit, profile.CreditLimit)
	}
	if !balance.IsZero() {
		t.Fatalf("expected zero balance for a brand new customer, got %s", balance)
	}
}

func TestCustomerCreate_DuplicateCodeRejected(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := customer.NewService(db)

	_, err := svc.Create(context.Background(), tenantID, customer.CreateInput{CustomerCode: "DUP001", Name: "First"})
	if err != nil {
		t.Fatalf("first create: %v", err)
	}
	_, err = svc.Create(context.Background(), tenantID, customer.CreateInput{CustomerCode: "DUP001", Name: "Second"})
	if err == nil {
		t.Fatal("expected duplicate customer_code to be rejected")
	}
}

func TestCustomerList_SearchesByNameCodeAndPhone(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := customer.NewService(db)

	if _, err := svc.Create(context.Background(), tenantID, customer.CreateInput{CustomerCode: "SEARCH01", Name: "Findable Farmer", Phone: "9998887770"}); err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, err := svc.Create(context.Background(), tenantID, customer.CreateInput{CustomerCode: "OTHER01", Name: "Someone Else", Phone: "1112223330"}); err != nil {
		t.Fatalf("create: %v", err)
	}

	byName, err := svc.List(context.Background(), tenantID, "Findable", 10)
	if err != nil {
		t.Fatalf("list by name: %v", err)
	}
	if len(byName) != 1 || byName[0].Name != "Findable Farmer" {
		t.Fatalf("expected exactly the matching customer by name, got %+v", byName)
	}

	byPhone, err := svc.List(context.Background(), tenantID, "9998887770", 10)
	if err != nil {
		t.Fatalf("list by phone: %v", err)
	}
	if len(byPhone) != 1 || byPhone[0].CustomerCode != "SEARCH01" {
		t.Fatalf("expected exactly the matching customer by phone, got %+v", byPhone)
	}

	all, err := svc.List(context.Background(), tenantID, "", 10)
	if err != nil {
		t.Fatalf("list all: %v", err)
	}
	if len(all) != 2 {
		t.Fatalf("expected 2 customers with an empty query, got %d", len(all))
	}
}

// TestCustomerList_ExcludesWalkingCustomer guards the "known customer only
// for credit" rule from the picker side: the Walking Customer must never
// appear as a selectable option in the same picker used for Khata credit
// billing, since selecting it and then choosing CREDIT is exactly the
// mistake pos.Service.FinalizeInvoice's hard, non-overridable rejection
// exists to prevent (defense in depth — this test guards the picker's
// half, the pos package's tests guard the finalize-time half).
func TestCustomerList_ExcludesWalkingCustomer(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := customer.NewService(db)

	if _, err := svc.Create(context.Background(), tenantID, customer.CreateInput{CustomerCode: "REAL01", Name: "Real Registered Customer"}); err != nil {
		t.Fatalf("create: %v", err)
	}
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		_, err := customer.GetOrCreateWalkIn(context.Background(), tx, tenantID)
		return err
	})
	if err != nil {
		t.Fatalf("create walk-in customer: %v", err)
	}

	all, err := svc.List(context.Background(), tenantID, "", 10)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(all) != 1 || all[0].CustomerCode != "REAL01" {
		t.Fatalf("expected only the real registered customer, walk-in must be excluded, got %+v", all)
	}

	byCode, err := svc.List(context.Background(), tenantID, customer.WalkInCustomerCode, 10)
	if err != nil {
		t.Fatalf("list by walk-in code: %v", err)
	}
	if len(byCode) != 0 {
		t.Fatalf("expected the Walking Customer to be unreachable even by an exact code search, got %+v", byCode)
	}
}

// TestCustomerList_IncludesOutstandingBalance guards the Khata directory
// list card feature: a shopkeeper must be able to see who owes money
// without opening each customer individually, so List's balance must match
// OutstandingBalance's own arithmetic (debit-credit), not just default to
// zero for every row.
func TestCustomerList_IncludesOutstandingBalance(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := customer.NewService(db)

	withBalance, err := svc.Create(context.Background(), tenantID, customer.CreateInput{CustomerCode: "OWES01", Name: "Owes Money"})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, err := svc.Create(context.Background(), tenantID, customer.CreateInput{CustomerCode: "CLEAN01", Name: "Clean Account"}); err != nil {
		t.Fatalf("create: %v", err)
	}

	err = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		_, err := customer.PostLedgerEntry(context.Background(), tx, tenantID, customer.LedgerEntry{
			CustomerID: withBalance.ID, DocumentType: "INVOICE", DocumentID: uuid.New(),
			Debit: decimal.RequireFromString("1500.00"), Credit: decimal.Zero, Description: "test sale",
		})
		return err
	})
	if err != nil {
		t.Fatalf("post ledger entry: %v", err)
	}

	all, err := svc.List(context.Background(), tenantID, "", 10)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	balances := map[string]decimal.Decimal{}
	for _, c := range all {
		balances[c.CustomerCode] = c.Balance
	}
	if !balances["OWES01"].Equal(decimal.RequireFromString("1500.00")) {
		t.Fatalf("expected OWES01 balance 1500.00, got %s (all: %+v)", balances["OWES01"], all)
	}
	if !balances["CLEAN01"].Equal(decimal.Zero) {
		t.Fatalf("expected CLEAN01 balance 0, got %s", balances["CLEAN01"])
	}
}

func TestCustomerSetCreditLimit_RequiresExistingCustomerAndNonNegative(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := customer.NewService(db)
	userID := uuid.New()

	created, err := svc.Create(context.Background(), tenantID, customer.CreateInput{CustomerCode: "CREDIT01", Name: "Credit Test"})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	if err := svc.SetCreditLimit(context.Background(), tenantID, created.ID, userID, decimal.RequireFromString("10000.00")); err != nil {
		t.Fatalf("set credit limit: %v", err)
	}
	_, profile, _, err := svc.GetByID(context.Background(), tenantID, created.ID)
	if err != nil {
		t.Fatalf("get by id: %v", err)
	}
	if !profile.CreditLimit.Equal(decimal.RequireFromString("10000.00")) {
		t.Fatalf("expected updated credit limit 10000.00, got %s", profile.CreditLimit)
	}

	if err := svc.SetCreditLimit(context.Background(), tenantID, created.ID, userID, decimal.RequireFromString("-100.00")); !errors.Is(err, customer.ErrValidation) {
		t.Fatalf("expected ErrValidation for negative credit limit, got: %v", err)
	}

	if err := svc.SetCreditLimit(context.Background(), tenantID, uuid.New(), userID, decimal.RequireFromString("100.00")); !errors.Is(err, customer.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a nonexistent customer, got: %v", err)
	}
}

func TestCustomerListLedger_ReturnsEntriesNewestFirstAndRejectsUnknownCustomer(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := customer.NewService(db)

	created, err := svc.Create(context.Background(), tenantID, customer.CreateInput{CustomerCode: "LEDGER01", Name: "Ledger Test"})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	invoiceID := uuid.New()
	receiptID := uuid.New()
	err = db.WithTenantTx(context.Background(), tenantID, func(tx pgx.Tx) error {
		if _, err := customer.PostLedgerEntry(context.Background(), tx, tenantID, customer.LedgerEntry{
			CustomerID: created.ID, DocumentType: "INVOICE", DocumentID: invoiceID,
			Debit: decimal.RequireFromString("500.00"), Description: "Credit sale INV-0001",
		}); err != nil {
			return err
		}
		_, err := customer.PostLedgerEntry(context.Background(), tx, tenantID, customer.LedgerEntry{
			CustomerID: created.ID, DocumentType: "RECEIPT", DocumentID: receiptID,
			Credit: decimal.RequireFromString("200.00"), Description: "Cash received",
		})
		return err
	})
	if err != nil {
		t.Fatalf("post ledger entries: %v", err)
	}

	entries, err := svc.ListLedger(context.Background(), tenantID, created.ID, 10)
	if err != nil {
		t.Fatalf("list ledger: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 ledger entries, got %d", len(entries))
	}
	// Newest-first: the receipt (posted second) must come before the invoice.
	if entries[0].DocumentType != "RECEIPT" || entries[1].DocumentType != "INVOICE" {
		t.Fatalf("expected [RECEIPT, INVOICE] order, got [%s, %s]", entries[0].DocumentType, entries[1].DocumentType)
	}
	if !entries[1].Debit.Equal(decimal.RequireFromString("500.00")) {
		t.Fatalf("expected invoice entry debit 500.00, got %s", entries[1].Debit)
	}
	if !entries[0].Credit.Equal(decimal.RequireFromString("200.00")) {
		t.Fatalf("expected receipt entry credit 200.00, got %s", entries[0].Credit)
	}

	if _, err := svc.ListLedger(context.Background(), tenantID, uuid.New(), 10); !errors.Is(err, customer.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a nonexistent customer, got: %v", err)
	}
}

// Regression test for a real bug reported live: the Flutter "Add Customer"
// dialog's default-selected and one alternate customer_type ("RETAIL",
// "WHOLESALE") did not match the customers_customer_type_check DB
// constraint (which only allows WALK_IN/FARMER/WHOLESALE_DEALER/
// AAVIN_SUBCONTRACTOR/OTHER), so every customer creation attempt with the
// default selection failed with an opaque 500 rather than a clear
// validation error. Fixed by validating customer_type against the exact
// same allow-list before ever reaching the database, and by fixing the
// Flutter dropdown's options to match.
func TestCustomerCreate_RejectsCustomerTypeNotInDBConstraint(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := customer.NewService(db)

	for _, badType := range []string{"RETAIL", "WHOLESALE", "WALK_IN", "made-up"} {
		_, err := svc.Create(context.Background(), tenantID, customer.CreateInput{
			CustomerCode: "BADTYPE-" + badType, Name: "Bad Type Customer", CustomerType: badType,
		})
		if !errors.Is(err, customer.ErrValidation) {
			t.Fatalf("expected ErrValidation for customer_type %q, got: %v", badType, err)
		}
	}

	for _, goodType := range []string{"FARMER", "WHOLESALE_DEALER", "AAVIN_SUBCONTRACTOR", "OTHER"} {
		_, err := svc.Create(context.Background(), tenantID, customer.CreateInput{
			CustomerCode: "GOODTYPE-" + goodType, Name: "Good Type Customer", CustomerType: goodType,
		})
		if err != nil {
			t.Fatalf("expected customer_type %q to be accepted, got: %v", goodType, err)
		}
	}
}

func TestCustomerUpdate_ChangesEditableFieldsNeverCode(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := customer.NewService(db)

	created, err := svc.Create(context.Background(), tenantID, customer.CreateInput{
		CustomerCode: "EDIT001", Name: "Original Name", Phone: "9000000000", CustomerType: "FARMER",
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	updated, err := svc.Update(context.Background(), tenantID, created.ID, customer.UpdateInput{
		Name: "Updated Name", Phone: "9111111111", Email: "updated@example.com", CustomerType: "WHOLESALE_DEALER",
	})
	if err != nil {
		t.Fatalf("update: %v", err)
	}
	if updated.Name != "Updated Name" {
		t.Fatalf("expected name 'Updated Name', got %q", updated.Name)
	}
	if updated.Phone == nil || *updated.Phone != "9111111111" {
		t.Fatalf("expected phone '9111111111', got %v", updated.Phone)
	}
	if updated.Email == nil || *updated.Email != "updated@example.com" {
		t.Fatalf("expected email to be set, got %v", updated.Email)
	}
	if updated.CustomerType != "WHOLESALE_DEALER" {
		t.Fatalf("expected customer_type 'WHOLESALE_DEALER', got %q", updated.CustomerType)
	}
	if updated.CustomerCode != "EDIT001" {
		t.Fatalf("customer_code must never change on update, got %q", updated.CustomerCode)
	}

	if _, err := svc.Update(context.Background(), tenantID, uuid.New(), customer.UpdateInput{Name: "X"}); !errors.Is(err, customer.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a nonexistent customer, got: %v", err)
	}
	if _, err := svc.Update(context.Background(), tenantID, created.ID, customer.UpdateInput{Name: ""}); !errors.Is(err, customer.ErrValidation) {
		t.Fatalf("expected ErrValidation for an empty name, got: %v", err)
	}
}

func TestCustomerSetActive_TogglesStatusWithoutHardDelete(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := customer.NewService(db)

	created, err := svc.Create(context.Background(), tenantID, customer.CreateInput{
		CustomerCode: "TOGGLE001", Name: "Toggle Test", CustomerType: "FARMER",
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	deactivated, err := svc.SetActive(context.Background(), tenantID, created.ID, false)
	if err != nil {
		t.Fatalf("deactivate: %v", err)
	}
	if deactivated.Status != "INACTIVE" {
		t.Fatalf("expected status INACTIVE, got %s", deactivated.Status)
	}

	// Never a hard delete — the row (and its history) must still exist and
	// be fetchable by id even while inactive.
	fetched, _, _, err := svc.GetByID(context.Background(), tenantID, created.ID)
	if err != nil {
		t.Fatalf("get by id after deactivate: %v", err)
	}
	if fetched.Status != "INACTIVE" {
		t.Fatalf("expected fetched status INACTIVE, got %s", fetched.Status)
	}

	reactivated, err := svc.SetActive(context.Background(), tenantID, created.ID, true)
	if err != nil {
		t.Fatalf("reactivate: %v", err)
	}
	if reactivated.Status != "ACTIVE" {
		t.Fatalf("expected status ACTIVE after reactivation, got %s", reactivated.Status)
	}

	if _, err := svc.SetActive(context.Background(), tenantID, uuid.New(), false); !errors.Is(err, customer.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a nonexistent customer, got: %v", err)
	}
}
