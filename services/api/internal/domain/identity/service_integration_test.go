//go:build integration

// Integration tests that run against a real, already-migrated PostgreSQL
// database (see scripts/test-integration.sh). They exercise the identity
// service exactly as the HTTP layer does, without going through HTTP, so they
// double as a fast regression check on the RLS/tenant-context wiring.
//
// Run with: go test -tags=integration ./internal/domain/identity/...
// Requires DATABASE_URL (app_user) and DATABASE_ADMIN_URL (app_admin) env vars
// pointing at a freshly migrated dev database.
package identity_test

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/auth"
	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/identity"
)

func mustEnv(t *testing.T, key string) string {
	t.Helper()
	v := os.Getenv(key)
	if v == "" {
		t.Skipf("%s not set; skipping integration test", key)
	}
	return v
}

// seedFixture creates an isolated tenant/device/user/role/permission set for
// this test run (unique UUIDs per run) via the admin path, and returns a
// cleanup function.
func seedFixture(t *testing.T, db *dbctx.DB, password string) (tenantID, deviceUUID uuid.UUID, username string) {
	t.Helper()
	ctx := context.Background()

	tenantID = uuid.New()
	deviceID := uuid.New()
	deviceUUID = uuid.New()
	roleID := uuid.New()
	userID := uuid.New()
	username = "itest_" + uuid.NewString()[:8]

	hash, err := auth.HashPassword(password, 4) // low cost for test speed
	if err != nil {
		t.Fatalf("hash password: %v", err)
	}

	err = db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO tenants (id, legal_name, address_line1, city, state_code) VALUES ($1,'Integration Test Tenant','1 Test St','Testville','TN')`, tenantID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO devices (id, tenant_id, device_uuid, display_name, platform, status) VALUES ($1,$2,$3,'Test Device','ANDROID','ACTIVE')`, deviceID, tenantID, deviceUUID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tenantID.String()); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO roles (id, tenant_id, name) VALUES ($1,$2,'Owner')`, roleID, tenantID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO role_permissions (tenant_id, role_id, permission_id) SELECT $1, $2, id FROM permissions WHERE code = 'pos.sell'`, tenantID, roleID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO users (id, tenant_id, username, password_hash, display_name, status) VALUES ($1,$2,$3,$4,'Test User','ACTIVE')`, userID, tenantID, username, hash); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO user_roles (tenant_id, user_id, role_id) VALUES ($1,$2,$3)`, tenantID, userID, roleID); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		t.Fatalf("seed fixture: %v", err)
	}

	t.Cleanup(func() {
		_ = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
			_, err := tx.Exec(context.Background(), `DELETE FROM tenants WHERE id = $1`, tenantID)
			return err
		})
	})

	return tenantID, deviceUUID, username
}

func TestLoginRefreshLogout(t *testing.T) {
	dsn := mustEnv(t, "DATABASE_URL")
	adminDSN := mustEnv(t, "DATABASE_ADMIN_URL")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	db, err := dbctx.Connect(ctx, dsn, adminDSN)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer db.Close()

	const password = "IntegrationTest123!"
	tenantID, deviceUUID, username := seedFixture(t, db, password)

	svc := identity.NewService(db, "test_signing_key", 15*time.Minute, 30*24*time.Hour, 4)

	t.Run("wrong password is rejected", func(t *testing.T) {
		_, err := svc.Login(context.Background(), deviceUUID, username, "wrong-password")
		if err == nil {
			t.Fatal("expected error for wrong password, got nil")
		}
	})

	t.Run("unknown device is rejected", func(t *testing.T) {
		_, err := svc.Login(context.Background(), uuid.New(), username, password)
		if err == nil {
			t.Fatal("expected error for unknown device, got nil")
		}
	})

	var refreshToken string
	t.Run("correct credentials succeed and carry the seeded permission", func(t *testing.T) {
		result, err := svc.Login(context.Background(), deviceUUID, username, password)
		if err != nil {
			t.Fatalf("login: %v", err)
		}
		if result.TenantID != tenantID {
			t.Fatalf("expected tenant %s, got %s", tenantID, result.TenantID)
		}
		if result.AccessToken == "" || result.RefreshToken == "" {
			t.Fatal("expected non-empty tokens")
		}
		found := false
		for _, p := range result.Permissions {
			if p == "pos.sell" {
				found = true
			}
		}
		if !found {
			t.Fatalf("expected pos.sell permission, got %v", result.Permissions)
		}
		refreshToken = result.RefreshToken
	})

	var rotatedToken string
	t.Run("refresh rotates the token", func(t *testing.T) {
		result, err := svc.Refresh(context.Background(), tenantID, refreshToken)
		if err != nil {
			t.Fatalf("refresh: %v", err)
		}
		if result.RefreshToken == refreshToken {
			t.Fatal("expected refresh token to be rotated")
		}
		rotatedToken = result.RefreshToken
	})

	t.Run("reusing the old refresh token fails", func(t *testing.T) {
		_, err := svc.Refresh(context.Background(), tenantID, refreshToken)
		if err == nil {
			t.Fatal("expected error reusing a rotated refresh token")
		}
	})

	t.Run("logout revokes the session", func(t *testing.T) {
		if err := svc.Logout(context.Background(), tenantID, rotatedToken); err != nil {
			t.Fatalf("logout: %v", err)
		}
		_, err := svc.Refresh(context.Background(), tenantID, rotatedToken)
		if err == nil {
			t.Fatal("expected refresh to fail after logout")
		}
	})
}
