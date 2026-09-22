//go:build integration

// Integration tests for the platform-admin control plane, run against a
// real migrated PostgreSQL database. Run with:
//
//	go test -tags=integration ./internal/domain/platformadmin/...
package platformadmin_test

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/auth"
	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/platformadmin"
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

// seedPlatformAdmin creates a fresh, isolated platform admin account for
// this test run and returns its username/password plus a cleanup.
func seedPlatformAdmin(t *testing.T, db *dbctx.DB, password string) (username string) {
	t.Helper()
	username = "padmin_" + uuid.NewString()[:8]
	hash, err := auth.HashPassword(password, 4)
	if err != nil {
		t.Fatalf("hash password: %v", err)
	}
	var id uuid.UUID
	if err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `
			INSERT INTO platform_admins (username, password_hash, display_name) VALUES ($1,$2,'Test Platform Admin') RETURNING id
		`, username, hash).Scan(&id)
	}); err != nil {
		t.Fatalf("seed platform admin: %v", err)
	}
	t.Cleanup(func() {
		_ = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
			if _, err := tx.Exec(context.Background(), `DELETE FROM platform_admin_sessions WHERE platform_admin_id = $1`, id); err != nil {
				return err
			}
			_, err := tx.Exec(context.Background(), `DELETE FROM platform_admins WHERE id = $1`, id)
			return err
		})
	})
	return username
}

func TestPlatformLogin_RefreshLogout(t *testing.T) {
	db := connectTest(t)
	defer db.Close()

	const password = "PlatformPass123!"
	username := seedPlatformAdmin(t, db, password)
	svc := platformadmin.NewService(db, "test_signing_key", 15*time.Minute, 30*24*time.Hour, 4)

	if _, err := svc.Login(context.Background(), username, "wrong-password"); !errors.Is(err, platformadmin.ErrInvalidCredentials) {
		t.Fatalf("expected ErrInvalidCredentials for wrong password, got: %v", err)
	}

	result, err := svc.Login(context.Background(), username, password)
	if err != nil {
		t.Fatalf("login: %v", err)
	}
	if result.AccessToken == "" || result.RefreshToken == "" {
		t.Fatal("expected non-empty tokens")
	}

	refreshed, err := svc.Refresh(context.Background(), result.RefreshToken)
	if err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if refreshed.RefreshToken == result.RefreshToken {
		t.Fatal("expected refresh token to be rotated")
	}

	if _, err := svc.Refresh(context.Background(), result.RefreshToken); !errors.Is(err, platformadmin.ErrRefreshTokenInvalid) {
		t.Fatalf("expected the old rotated-out token to be rejected, got: %v", err)
	}

	if err := svc.Logout(context.Background(), refreshed.RefreshToken); err != nil {
		t.Fatalf("logout: %v", err)
	}
	if _, err := svc.Refresh(context.Background(), refreshed.RefreshToken); !errors.Is(err, platformadmin.ErrRefreshTokenInvalid) {
		t.Fatalf("expected refresh to fail after logout, got: %v", err)
	}
}

func newTestInput(suffix string) platformadmin.CreateTenantInput {
	return platformadmin.CreateTenantInput{
		LegalName: "Platform Test Tenant " + suffix, AddressLine1: "1 Test St", City: "Testville", StateCode: "TN",
		OwnerUsername: "owner_" + suffix, OwnerPassword: "OwnerPass123!", OwnerName: "Test Owner",
	}
}

func TestCreateTenant_BootstrapsEverythingNeededToOperate(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	svc := platformadmin.NewService(db, "test_signing_key", 15*time.Minute, 30*24*time.Hour, 4)

	suffix := uuid.NewString()[:8]
	tenantID, ownerUserID, err := svc.CreateTenant(context.Background(), newTestInput(suffix))
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	t.Cleanup(func() {
		_ = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
			_, err := tx.Exec(context.Background(), `DELETE FROM tenants WHERE id = $1`, tenantID)
			return err
		})
	})
	if tenantID == uuid.Nil || ownerUserID == uuid.Nil {
		t.Fatal("expected non-nil tenant and owner ids")
	}

	detail, err := svc.GetTenant(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("get tenant: %v", err)
	}
	if detail.PlanCode != "TRIAL" {
		t.Fatalf("expected default plan TRIAL, got %q", detail.PlanCode)
	}
	if detail.Status != "ACTIVE" {
		t.Fatalf("expected a new tenant to start ACTIVE, got %q", detail.Status)
	}

	// The owner must actually be able to log in and immediately do
	// everything tenant.admin-gated — i.e. the Owner role really has every
	// permission, not just a plausible-looking subset.
	var roleCount, permCount, financialYearCount, seriesCount int
	if err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		if err := tx.QueryRow(context.Background(), `SELECT count(*) FROM roles WHERE tenant_id = $1 AND name = 'Owner'`, tenantID).Scan(&roleCount); err != nil {
			return err
		}
		if err := tx.QueryRow(context.Background(), `
			SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.tenant_id = $1
		`, tenantID).Scan(&permCount); err != nil {
			return err
		}
		var totalPerms int
		if err := tx.QueryRow(context.Background(), `SELECT count(*) FROM permissions`).Scan(&totalPerms); err != nil {
			return err
		}
		if permCount != totalPerms {
			t.Fatalf("expected Owner role to have all %d permissions, got %d", totalPerms, permCount)
		}
		if err := tx.QueryRow(context.Background(), `SELECT count(*) FROM financial_years WHERE tenant_id = $1 AND status = 'OPEN'`, tenantID).Scan(&financialYearCount); err != nil {
			return err
		}
		if err := tx.QueryRow(context.Background(), `SELECT count(*) FROM document_series WHERE tenant_id = $1 AND active`, tenantID).Scan(&seriesCount); err != nil {
			return err
		}
		return nil
	}); err != nil {
		t.Fatalf("verify bootstrap: %v", err)
	}
	if roleCount != 1 {
		t.Fatalf("expected exactly one Owner role, got %d", roleCount)
	}
	if financialYearCount != 1 {
		t.Fatalf("expected exactly one open financial year, got %d", financialYearCount)
	}
	if seriesCount != 4 {
		t.Fatalf("expected 4 active document series (INVOICE/GRN/RETURN/CONTRA), got %d", seriesCount)
	}

	// Duplicate owner_username within the same call is a DB-level unique
	// violation caught by CreateTenant's own transaction — verifying the
	// validation path instead: an empty legal name is rejected before any
	// DB work happens.
	badInput := newTestInput(suffix)
	badInput.LegalName = ""
	if _, _, err := svc.CreateTenant(context.Background(), badInput); !errors.Is(err, platformadmin.ErrValidation) {
		t.Fatalf("expected ErrValidation for empty legal_name, got: %v", err)
	}
}

func TestTenantLifecycle_StatusPlanBrandingAndFeatures(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	svc := platformadmin.NewService(db, "test_signing_key", 15*time.Minute, 30*24*time.Hour, 4)

	suffix := uuid.NewString()[:8]
	tenantID, _, err := svc.CreateTenant(context.Background(), newTestInput(suffix))
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	t.Cleanup(func() {
		_ = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
			_, err := tx.Exec(context.Background(), `DELETE FROM tenants WHERE id = $1`, tenantID)
			return err
		})
	})

	if err := svc.SetTenantStatus(context.Background(), tenantID, "SUSPENDED"); err != nil {
		t.Fatalf("suspend: %v", err)
	}
	detail, err := svc.GetTenant(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("get tenant: %v", err)
	}
	if detail.Status != "SUSPENDED" {
		t.Fatalf("expected SUSPENDED, got %q", detail.Status)
	}

	if err := svc.SetTenantStatus(context.Background(), tenantID, "NOT_A_REAL_STATUS"); !errors.Is(err, platformadmin.ErrValidation) {
		t.Fatalf("expected ErrValidation for an invalid status, got: %v", err)
	}

	expiry := time.Now().Add(30 * 24 * time.Hour).Truncate(time.Second)
	if err := svc.SetTenantPlan(context.Background(), tenantID, "PRO", &expiry); err != nil {
		t.Fatalf("set plan: %v", err)
	}

	appName := "Client's Own Feed App"
	color := "#00A86B"
	if err := svc.SetTenantBranding(context.Background(), tenantID, &appName, nil, &color); err != nil {
		t.Fatalf("set branding: %v", err)
	}

	if err := svc.SetTenantFeature(context.Background(), tenantID, "advanced_reports", true); err != nil {
		t.Fatalf("set feature: %v", err)
	}

	detail, err = svc.GetTenant(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("get tenant after updates: %v", err)
	}
	if detail.PlanCode != "PRO" || detail.PlanExpiresAt == nil || !detail.PlanExpiresAt.Equal(expiry) {
		t.Fatalf("expected plan PRO expiring %v, got %q / %v", expiry, detail.PlanCode, detail.PlanExpiresAt)
	}
	if detail.AppDisplayName == nil || *detail.AppDisplayName != appName {
		t.Fatalf("expected app_display_name %q, got %+v", appName, detail.AppDisplayName)
	}
	if detail.PrimaryColor == nil || *detail.PrimaryColor != color {
		t.Fatalf("expected primary_color %q, got %+v", color, detail.PrimaryColor)
	}
	if !detail.Features["advanced_reports"] {
		t.Fatalf("expected advanced_reports feature enabled, got %+v", detail.Features)
	}

	// Operating on a nonexistent tenant must fail cleanly, not silently.
	if err := svc.SetTenantStatus(context.Background(), uuid.New(), "ACTIVE"); !errors.Is(err, platformadmin.ErrNotFound) {
		t.Fatalf("expected ErrNotFound, got: %v", err)
	}
}

func TestListTenants_IncludesNewlyCreatedOne(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	svc := platformadmin.NewService(db, "test_signing_key", 15*time.Minute, 30*24*time.Hour, 4)

	suffix := uuid.NewString()[:8]
	tenantID, _, err := svc.CreateTenant(context.Background(), newTestInput(suffix))
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	t.Cleanup(func() {
		_ = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
			_, err := tx.Exec(context.Background(), `DELETE FROM tenants WHERE id = $1`, tenantID)
			return err
		})
	})

	tenants, err := svc.ListTenants(context.Background())
	if err != nil {
		t.Fatalf("list tenants: %v", err)
	}
	found := false
	for _, t2 := range tenants {
		if t2.ID == tenantID {
			found = true
			if t2.UserCount != 1 {
				t.Fatalf("expected exactly 1 user (the owner) counted, got %d", t2.UserCount)
			}
		}
	}
	if !found {
		t.Fatal("expected the newly created tenant to appear in ListTenants")
	}
}

func TestBranding_FallsBackToPlatformDefaultThenTenantOverride(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	svc := platformadmin.NewService(db, "test_signing_key", 15*time.Minute, 30*24*time.Hour, 4)

	// No device_uuid at all — the login screen's very first paint, before
	// any device identity is even relevant — must still resolve to
	// *something* sane (the seeded platform default), never an error.
	branding, err := svc.ResolveBranding(context.Background(), nil)
	if err != nil {
		t.Fatalf("resolve branding with nil device: %v", err)
	}
	if branding.AppName == "" {
		t.Fatal("expected a non-empty platform default app name")
	}
	originalAppName := branding.AppName

	// An unrecognized device_uuid must fall back the same way, not error.
	randomDevice := uuid.New()
	branding, err = svc.ResolveBranding(context.Background(), &randomDevice)
	if err != nil {
		t.Fatalf("resolve branding with unknown device: %v", err)
	}
	if branding.AppName != originalAppName {
		t.Fatalf("expected platform default for an unknown device, got %q", branding.AppName)
	}

	// A real device belonging to a tenant with no branding override set
	// must also fall back to the platform default.
	suffix := uuid.NewString()[:8]
	tenantID, _, err := svc.CreateTenant(context.Background(), newTestInput(suffix))
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	t.Cleanup(func() {
		_ = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
			_, err := tx.Exec(context.Background(), `DELETE FROM tenants WHERE id = $1`, tenantID)
			return err
		})
	})
	deviceUUID := uuid.New()
	if err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(), `
			INSERT INTO devices (tenant_id, device_uuid, display_name, platform, status) VALUES ($1,$2,'Test Device','ANDROID','ACTIVE')
		`, tenantID, deviceUUID)
		return err
	}); err != nil {
		t.Fatalf("seed device: %v", err)
	}

	branding, err = svc.ResolveBranding(context.Background(), &deviceUUID)
	if err != nil {
		t.Fatalf("resolve branding for a tenant with no override: %v", err)
	}
	if branding.AppName != originalAppName {
		t.Fatalf("expected platform default when tenant has no override, got %q", branding.AppName)
	}

	// Once the tenant sets its own app_display_name, that device's branding
	// must reflect it — this is the actual whitelabel behavior.
	customName := "Client's Own Feed Store"
	if err := svc.SetTenantBranding(context.Background(), tenantID, &customName, nil, nil); err != nil {
		t.Fatalf("set tenant branding: %v", err)
	}
	branding, err = svc.ResolveBranding(context.Background(), &deviceUUID)
	if err != nil {
		t.Fatalf("resolve branding after override: %v", err)
	}
	if branding.AppName != customName {
		t.Fatalf("expected tenant override %q, got %q", customName, branding.AppName)
	}
	// The tagline was never overridden — it must still come from the
	// platform default, proving the merge is field-by-field, not all-or-nothing.
	if branding.AppTagline == "" {
		t.Fatal("expected the platform default tagline to still apply")
	}
}

func TestPlatformSettings_GetAndUpdate(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	svc := platformadmin.NewService(db, "test_signing_key", 15*time.Minute, 30*24*time.Hour, 4)

	original, err := svc.GetPlatformSettings(context.Background())
	if err != nil {
		t.Fatalf("get platform settings: %v", err)
	}
	t.Cleanup(func() {
		_ = svc.UpdatePlatformSettings(context.Background(), original.AppName, original.AppTagline, original.LogoURL, original.PrimaryColor)
	})

	newTagline := "Integration Test Tagline " + uuid.NewString()[:8]
	if err := svc.UpdatePlatformSettings(context.Background(), "Test App Name", newTagline, nil, nil); err != nil {
		t.Fatalf("update platform settings: %v", err)
	}

	updated, err := svc.GetPlatformSettings(context.Background())
	if err != nil {
		t.Fatalf("get platform settings after update: %v", err)
	}
	if updated.AppName != "Test App Name" || updated.AppTagline != newTagline {
		t.Fatalf("expected updated settings, got %+v", updated)
	}

	if err := svc.UpdatePlatformSettings(context.Background(), "", "tagline", nil, nil); !errors.Is(err, platformadmin.ErrValidation) {
		t.Fatalf("expected ErrValidation for empty app_name, got: %v", err)
	}
}

func TestErrorLogs_RecordAndList(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	svc := platformadmin.NewService(db, "test_signing_key", 15*time.Minute, 30*24*time.Hour, 4)

	reqID := uuid.New()
	if err := svc.RecordError(context.Background(), &reqID, 500, "a distinctive test error message "+reqID.String()); err != nil {
		t.Fatalf("record error: %v", err)
	}

	entries, err := svc.ListErrorLogs(context.Background(), 50, 0)
	if err != nil {
		t.Fatalf("list error logs: %v", err)
	}
	found := false
	for _, e := range entries {
		if e.RequestID != nil && *e.RequestID == reqID {
			found = true
			if e.StatusCode != 500 {
				t.Fatalf("expected status 500, got %d", e.StatusCode)
			}
		}
	}
	if !found {
		t.Fatal("expected the recorded error to appear in ListErrorLogs")
	}
}
