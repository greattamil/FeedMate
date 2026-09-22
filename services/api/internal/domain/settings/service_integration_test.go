//go:build integration

// Integration tests against a real, migrated PostgreSQL database. Run with:
//
//	go test -tags=integration ./internal/domain/settings/...
//
// Requires DATABASE_URL (app_user) and DATABASE_ADMIN_URL (app_admin).
package settings_test

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/settings"
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

func seedTenantAndUser(t *testing.T, db *dbctx.DB) (uuid.UUID, uuid.UUID) {
	t.Helper()
	tenantID := uuid.New()
	userID := uuid.New()
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		ctx := context.Background()
		if _, err := tx.Exec(ctx, `
			INSERT INTO tenants (id, legal_name, address_line1, city, state_code, invoice_prefix)
			VALUES ($1,'Settings Test Tenant','1 St','Town','TN','INV')
		`, tenantID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO tenant_settings (tenant_id) VALUES ($1)`, tenantID); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO users (id, tenant_id, username, password_hash, display_name, status) VALUES ($1,$2,'settingsuser','x','Settings Test User','ACTIVE')`, userID, tenantID)
		return err
	})
	if err != nil {
		t.Fatalf("seed tenant/user: %v", err)
	}
	t.Cleanup(func() {
		_ = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
			_, err := tx.Exec(context.Background(), `DELETE FROM tenants WHERE id = $1`, tenantID)
			return err
		})
	})
	return tenantID, userID
}

func strPtr(s string) *string { return &s }

func TestGetStoreProfile_ReturnsSeededDefaults(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID, _ := seedTenantAndUser(t, db)
	svc := settings.NewService(db)

	p, err := svc.GetStoreProfile(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("get store profile: %v", err)
	}
	if p.LegalName != "Settings Test Tenant" {
		t.Fatalf("expected seeded legal name, got %q", p.LegalName)
	}
	if p.InvoicePrefix != "INV" {
		t.Fatalf("expected seeded invoice prefix, got %q", p.InvoicePrefix)
	}
	if p.ReceiptHeader != nil || p.ReceiptFooter != nil {
		t.Fatalf("expected no receipt text yet, got header=%v footer=%v", p.ReceiptHeader, p.ReceiptFooter)
	}
}

func TestUpdateStoreProfile_PersistsProfileAndReceiptTextAndAudits(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID, userID := seedTenantAndUser(t, db)
	svc := settings.NewService(db)

	update := settings.StoreProfile{
		LegalName:     "Andipatti Animal Feed System",
		TradeName:     strPtr("AAFS"),
		GSTIN:         strPtr("33AAAAA0000A1Z5"),
		Phone:         strPtr("9876543210"),
		AddressLine1:  "12 Market Road",
		City:          "Andipatti",
		StateCode:     "TN",
		InvoicePrefix: "AAFS",
		ReceiptHeader: strPtr("Andipatti Animal Feed System"),
		ReceiptFooter: strPtr("Thank you, visit again!"),
	}
	if err := svc.UpdateStoreProfile(context.Background(), tenantID, userID, update); err != nil {
		t.Fatalf("update store profile: %v", err)
	}

	got, err := svc.GetStoreProfile(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("get store profile after update: %v", err)
	}
	if got.LegalName != update.LegalName {
		t.Fatalf("expected legal_name %q, got %q", update.LegalName, got.LegalName)
	}
	if got.TradeName == nil || *got.TradeName != "AAFS" {
		t.Fatalf("expected trade_name AAFS, got %v", got.TradeName)
	}
	if got.ReceiptHeader == nil || *got.ReceiptHeader != "Andipatti Animal Feed System" {
		t.Fatalf("expected receipt header persisted, got %v", got.ReceiptHeader)
	}
	if got.ReceiptFooter == nil || *got.ReceiptFooter != "Thank you, visit again!" {
		t.Fatalf("expected receipt footer persisted, got %v", got.ReceiptFooter)
	}

	err = db.WithTenantReadTx(context.Background(), tenantID, func(tx pgx.Tx) error {
		var actionCode string
		return tx.QueryRow(context.Background(),
			`SELECT action_code FROM audit_logs WHERE tenant_id = $1 AND action_code = 'TENANT_SETTINGS_UPDATED'`, tenantID).Scan(&actionCode)
	})
	if err != nil {
		t.Fatalf("expected an audit log entry for the update: %v", err)
	}
}

func TestUpdateStoreProfile_PersistsLogoDataURI(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID, userID := seedTenantAndUser(t, db)
	svc := settings.NewService(db)

	const logo = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
	update := settings.StoreProfile{
		LegalName:     "Logo Test Tenant",
		AddressLine1:  "12 Market Road",
		City:          "Andipatti",
		StateCode:     "TN",
		InvoicePrefix: "LOGO",
		LogoDataURI:   strPtr(logo),
	}
	if err := svc.UpdateStoreProfile(context.Background(), tenantID, userID, update); err != nil {
		t.Fatalf("update store profile with logo: %v", err)
	}

	got, err := svc.GetStoreProfile(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("get store profile after logo update: %v", err)
	}
	if got.LogoDataURI == nil || *got.LogoDataURI != logo {
		t.Fatalf("expected logo data URI persisted, got %v", got.LogoDataURI)
	}

	// Clearing it (nil) must actually remove the key, not just leave it stale.
	update.LogoDataURI = nil
	if err := svc.UpdateStoreProfile(context.Background(), tenantID, userID, update); err != nil {
		t.Fatalf("clear logo: %v", err)
	}
	got, err = svc.GetStoreProfile(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("get store profile after clearing logo: %v", err)
	}
	if got.LogoDataURI != nil {
		t.Fatalf("expected logo cleared, got %v", *got.LogoDataURI)
	}
}

func TestUpdateStoreProfile_RejectsInvalidLogoDataURI(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID, userID := seedTenantAndUser(t, db)
	svc := settings.NewService(db)

	update := settings.StoreProfile{
		LegalName:     "Bad Logo Tenant",
		AddressLine1:  "12 Market Road",
		City:          "Andipatti",
		StateCode:     "TN",
		InvoicePrefix: "BADLOGO",
		LogoDataURI:   strPtr("not-a-data-uri"),
	}
	err := svc.UpdateStoreProfile(context.Background(), tenantID, userID, update)
	if !errors.Is(err, settings.ErrValidation) {
		t.Fatalf("expected ErrValidation for malformed logo data URI, got %v", err)
	}
}

func TestUpdateStoreProfile_RejectsOversizedLogoDataURI(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID, userID := seedTenantAndUser(t, db)
	svc := settings.NewService(db)

	oversized := "data:image/png;base64," + strings.Repeat("A", 1_600_000)
	update := settings.StoreProfile{
		LegalName:     "Oversized Logo Tenant",
		AddressLine1:  "12 Market Road",
		City:          "Andipatti",
		StateCode:     "TN",
		InvoicePrefix: "BIGLOGO",
		LogoDataURI:   strPtr(oversized),
	}
	err := svc.UpdateStoreProfile(context.Background(), tenantID, userID, update)
	if !errors.Is(err, settings.ErrValidation) {
		t.Fatalf("expected ErrValidation for oversized logo data URI, got %v", err)
	}
}

func TestUpdateStoreProfile_RejectsMissingRequiredFields(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID, userID := seedTenantAndUser(t, db)
	svc := settings.NewService(db)

	update := settings.StoreProfile{
		LegalName:     "",
		AddressLine1:  "12 Market Road",
		City:          "Andipatti",
		StateCode:     "TN",
		InvoicePrefix: "AAFS",
	}
	err := svc.UpdateStoreProfile(context.Background(), tenantID, userID, update)
	if !errors.Is(err, settings.ErrValidation) {
		t.Fatalf("expected ErrValidation for missing legal_name, got %v", err)
	}
}
