//go:build integration

package supplier_test

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
		_, err := tx.Exec(context.Background(), `INSERT INTO tenants (id, legal_name, address_line1, city, state_code) VALUES ($1,'Supplier Test Tenant','1 St','Town','TN')`, tenantID)
		return err
	})
	if err != nil {
		t.Fatalf("seed tenant: %v", err)
	}
	t.Cleanup(func() {
		_ = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
			ctx := context.Background()
			for _, stmt := range []string{
				`DELETE FROM supplier_ledger_entries WHERE tenant_id = $1`,
				`DELETE FROM suppliers WHERE tenant_id = $1`,
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

func TestSupplierCreateAndFetch(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := supplier.NewService(db)

	created, err := svc.Create(context.Background(), tenantID, supplier.CreateInput{
		SupplierCode: "SUP001", Name: "Test Feed Mill", GSTIN: "29ABCDE1234F1Z5",
		Phone: "9876543210", PaymentTermsDays: 30,
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if created.Status != "ACTIVE" {
		t.Fatalf("expected newly created supplier to be ACTIVE, got %s", created.Status)
	}

	fetched, balance, err := svc.GetByID(context.Background(), tenantID, created.ID)
	if err != nil {
		t.Fatalf("get by id: %v", err)
	}
	if fetched.Name != "Test Feed Mill" {
		t.Fatalf("expected name 'Test Feed Mill', got %q", fetched.Name)
	}
	if !balance.IsZero() {
		t.Fatalf("expected zero payable for a brand new supplier, got %s", balance)
	}
}

func TestSupplierCreate_ValidatesRequiredFields(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := supplier.NewService(db)

	if _, err := svc.Create(context.Background(), tenantID, supplier.CreateInput{Name: "No Code"}); !errors.Is(err, supplier.ErrValidation) {
		t.Fatalf("expected ErrValidation for missing supplier_code, got: %v", err)
	}
	if _, err := svc.Create(context.Background(), tenantID, supplier.CreateInput{SupplierCode: "SUP002"}); !errors.Is(err, supplier.ErrValidation) {
		t.Fatalf("expected ErrValidation for missing name, got: %v", err)
	}
	if _, err := svc.Create(context.Background(), tenantID, supplier.CreateInput{SupplierCode: "SUP003", Name: "X", PaymentTermsDays: -1}); !errors.Is(err, supplier.ErrValidation) {
		t.Fatalf("expected ErrValidation for negative payment_terms_days, got: %v", err)
	}
}

func TestSupplierList_SearchesByNameCodeAndGstin(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := supplier.NewService(db)

	if _, err := svc.Create(context.Background(), tenantID, supplier.CreateInput{SupplierCode: "SEARCH01", Name: "Findable Mill", GSTIN: "29AAAAA0000A1Z1"}); err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, err := svc.Create(context.Background(), tenantID, supplier.CreateInput{SupplierCode: "OTHER01", Name: "Someone Else Mill"}); err != nil {
		t.Fatalf("create: %v", err)
	}

	byName, err := svc.List(context.Background(), tenantID, "Findable", 10)
	if err != nil {
		t.Fatalf("list by name: %v", err)
	}
	if len(byName) != 1 || byName[0].Name != "Findable Mill" {
		t.Fatalf("expected exactly the matching supplier by name, got %+v", byName)
	}

	byGstin, err := svc.List(context.Background(), tenantID, "29AAAAA0000A1Z1", 10)
	if err != nil {
		t.Fatalf("list by gstin: %v", err)
	}
	if len(byGstin) != 1 || byGstin[0].SupplierCode != "SEARCH01" {
		t.Fatalf("expected exactly the matching supplier by GSTIN, got %+v", byGstin)
	}

	all, err := svc.List(context.Background(), tenantID, "", 10)
	if err != nil {
		t.Fatalf("list all: %v", err)
	}
	if len(all) != 2 {
		t.Fatalf("expected 2 suppliers with an empty query, got %d", len(all))
	}
}

func TestSupplierListLedger_ReturnsEntriesNewestFirstAndRejectsUnknownSupplier(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := supplier.NewService(db)

	created, err := svc.Create(context.Background(), tenantID, supplier.CreateInput{SupplierCode: "LEDGER01", Name: "Ledger Test Mill"})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	grnID := uuid.New()
	paymentID := uuid.New()
	err = db.WithTenantTx(context.Background(), tenantID, func(tx pgx.Tx) error {
		if _, err := supplier.PostLedgerEntry(context.Background(), tx, tenantID, supplier.LedgerEntry{
			SupplierID: created.ID, DocumentType: "GRN", DocumentID: grnID,
			Credit: decimal.RequireFromString("10000.00"), Description: "GRN received",
		}); err != nil {
			return err
		}
		_, err := supplier.PostLedgerEntry(context.Background(), tx, tenantID, supplier.LedgerEntry{
			SupplierID: created.ID, DocumentType: "PAYMENT", DocumentID: paymentID,
			Debit: decimal.RequireFromString("4000.00"), Description: "Cash payment",
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
	// Newest-first: the payment (posted second) must come before the GRN.
	if entries[0].DocumentType != "PAYMENT" || entries[1].DocumentType != "GRN" {
		t.Fatalf("expected [PAYMENT, GRN] order, got [%s, %s]", entries[0].DocumentType, entries[1].DocumentType)
	}

	if _, err := svc.ListLedger(context.Background(), tenantID, uuid.New(), 10); !errors.Is(err, supplier.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a nonexistent supplier, got: %v", err)
	}
}

func TestSupplierUpdate_RevisesFieldsButNeverSupplierCode(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := supplier.NewService(db)

	created, err := svc.Create(context.Background(), tenantID, supplier.CreateInput{
		SupplierCode: "UPD001", Name: "Original Mill", Phone: "9000000001", PaymentTermsDays: 15,
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	updated, err := svc.Update(context.Background(), tenantID, created.ID, supplier.UpdateInput{
		Name: "Renamed Mill", TradeName: "Renamed Trade Co", GSTIN: "29ZZZZZ0000Z1Z1",
		Phone: "9000000002", Email: "renamed@example.com", PaymentTermsDays: 45,
	})
	if err != nil {
		t.Fatalf("update: %v", err)
	}
	if updated.SupplierCode != "UPD001" {
		t.Fatalf("supplier_code must never change on update, got %q", updated.SupplierCode)
	}
	if updated.Name != "Renamed Mill" || updated.PaymentTermsDays != 45 || updated.Phone == nil || *updated.Phone != "9000000002" {
		t.Fatalf("expected revised fields, got %+v", updated)
	}
	if updated.TradeName == nil || *updated.TradeName != "Renamed Trade Co" {
		t.Fatalf("expected trade_name to be set, got %+v", updated.TradeName)
	}

	fetched, _, err := svc.GetByID(context.Background(), tenantID, created.ID)
	if err != nil {
		t.Fatalf("get by id: %v", err)
	}
	if fetched.Name != "Renamed Mill" {
		t.Fatalf("expected persisted rename, got %q", fetched.Name)
	}

	if _, err := svc.Update(context.Background(), tenantID, created.ID, supplier.UpdateInput{Name: "", PaymentTermsDays: 0}); !errors.Is(err, supplier.ErrValidation) {
		t.Fatalf("expected ErrValidation for missing name, got: %v", err)
	}
	if _, err := svc.Update(context.Background(), tenantID, created.ID, supplier.UpdateInput{Name: "X", PaymentTermsDays: -1}); !errors.Is(err, supplier.ErrValidation) {
		t.Fatalf("expected ErrValidation for negative payment_terms_days, got: %v", err)
	}
	if _, err := svc.Update(context.Background(), tenantID, uuid.New(), supplier.UpdateInput{Name: "X"}); !errors.Is(err, supplier.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a nonexistent supplier, got: %v", err)
	}
}

func TestSupplierSetActive_NeverHardDeletes(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := supplier.NewService(db)

	created, err := svc.Create(context.Background(), tenantID, supplier.CreateInput{SupplierCode: "DEACT01", Name: "Deactivate Test Mill"})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	deactivated, err := svc.SetActive(context.Background(), tenantID, created.ID, false)
	if err != nil {
		t.Fatalf("deactivate: %v", err)
	}
	if deactivated.Status != "INACTIVE" {
		t.Fatalf("expected INACTIVE, got %s", deactivated.Status)
	}

	// Still findable by ID — a deactivation is a status flip, never a
	// hard delete, since historical GRN/payment rows reference this row.
	fetched, _, err := svc.GetByID(context.Background(), tenantID, created.ID)
	if err != nil {
		t.Fatalf("get by id after deactivate: %v", err)
	}
	if fetched.Status != "INACTIVE" {
		t.Fatalf("expected persisted INACTIVE status, got %s", fetched.Status)
	}

	// An inactive supplier is excluded from the default active-only List.
	active, err := svc.List(context.Background(), tenantID, "Deactivate Test Mill", 10)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(active) != 0 {
		t.Fatalf("expected deactivated supplier to be excluded from List, got %+v", active)
	}

	reactivated, err := svc.SetActive(context.Background(), tenantID, created.ID, true)
	if err != nil {
		t.Fatalf("reactivate: %v", err)
	}
	if reactivated.Status != "ACTIVE" {
		t.Fatalf("expected ACTIVE after reactivation, got %s", reactivated.Status)
	}

	if _, err := svc.SetActive(context.Background(), tenantID, uuid.New(), false); !errors.Is(err, supplier.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a nonexistent supplier, got: %v", err)
	}
}
