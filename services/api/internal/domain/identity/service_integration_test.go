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
	"errors"
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

func TestCreateUser_ListsAndAssignsRolesAndRejectsDuplicateUsername(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID, _, _ := seedFixture(t, db, "IntegrationTest123!")
	svc := identity.NewService(db, "test_signing_key", 15*time.Minute, 30*24*time.Hour, 4)

	roles, err := svc.ListRoles(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list roles: %v", err)
	}
	if len(roles) != 1 || roles[0].Name != "Owner" {
		t.Fatalf("expected exactly the seeded Owner role, got %+v", roles)
	}
	ownerRoleID := roles[0].ID

	newUsername := "cashier_" + uuid.NewString()[:8]
	userID, err := svc.CreateUser(context.Background(), tenantID, identity.CreateUserInput{
		Username: newUsername, Password: "a-strong-password", DisplayName: "New Cashier",
		Phone: "9876543210", RoleIDs: []uuid.UUID{ownerRoleID},
	})
	if err != nil {
		t.Fatalf("create user: %v", err)
	}

	page, err := svc.ListUsers(context.Background(), tenantID, "", 10, 0)
	if err != nil {
		t.Fatalf("list users: %v", err)
	}
	// The fixture's own "Test User" plus the one just created.
	if page.Total != 2 {
		t.Fatalf("expected total 2 users, got %d", page.Total)
	}

	detail, err := svc.GetUserDetail(context.Background(), tenantID, userID)
	if err != nil {
		t.Fatalf("get user detail: %v", err)
	}
	if detail.User.DisplayName != "New Cashier" || detail.User.Phone == nil || *detail.User.Phone != "9876543210" {
		t.Fatalf("expected the new user's profile fields, got %+v", detail.User)
	}
	if len(detail.RoleIDs) != 1 || detail.RoleIDs[0] != ownerRoleID {
		t.Fatalf("expected the Owner role assigned, got %+v", detail.RoleIDs)
	}

	if _, err := svc.CreateUser(context.Background(), tenantID, identity.CreateUserInput{
		Username: newUsername, Password: "another-password", DisplayName: "Duplicate",
	}); !errors.Is(err, identity.ErrUsernameTaken) {
		t.Fatalf("expected ErrUsernameTaken for a duplicate username, got: %v", err)
	}

	if _, err := svc.CreateUser(context.Background(), tenantID, identity.CreateUserInput{
		Username: "short_pw_user", Password: "short", DisplayName: "X",
	}); !errors.Is(err, identity.ErrValidation) {
		t.Fatalf("expected ErrValidation for a too-short password, got: %v", err)
	}
}

func TestSetUserStatus_DeactivatedUserCannotLogIn(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	const password = "IntegrationTest123!"
	tenantID, deviceUUID, username := seedFixture(t, db, password)
	svc := identity.NewService(db, "test_signing_key", 15*time.Minute, 30*24*time.Hour, 4)

	var userID uuid.UUID
	err := db.WithTenantReadTx(context.Background(), tenantID, func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT id FROM users WHERE username = $1`, username).Scan(&userID)
	})
	if err != nil {
		t.Fatalf("look up seeded user id: %v", err)
	}

	if _, err := svc.Login(context.Background(), deviceUUID, username, password); err != nil {
		t.Fatalf("login before deactivation should succeed: %v", err)
	}

	if err := svc.SetUserStatus(context.Background(), tenantID, userID, false); err != nil {
		t.Fatalf("deactivate user: %v", err)
	}

	if _, err := svc.Login(context.Background(), deviceUUID, username, password); !errors.Is(err, identity.ErrInvalidCredentials) {
		t.Fatalf("expected login to be rejected after deactivation, got: %v", err)
	}

	if err := svc.SetUserStatus(context.Background(), tenantID, userID, true); err != nil {
		t.Fatalf("reactivate user: %v", err)
	}
	if _, err := svc.Login(context.Background(), deviceUUID, username, password); err != nil {
		t.Fatalf("login after reactivation should succeed: %v", err)
	}

	if err := svc.SetUserStatus(context.Background(), tenantID, uuid.New(), false); !errors.Is(err, identity.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a nonexistent user, got: %v", err)
	}
}

func TestSetUserRoles_ReplacesFullAssignmentSet(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID, _, _ := seedFixture(t, db, "IntegrationTest123!")
	svc := identity.NewService(db, "test_signing_key", 15*time.Minute, 30*24*time.Hour, 4)

	ownerRoleID := uuid.New()
	cashierRoleID := uuid.New()
	err := db.WithTenantTx(context.Background(), tenantID, func(tx pgx.Tx) error {
		if _, err := tx.Exec(context.Background(), `INSERT INTO roles (id, tenant_id, name) VALUES ($1,$2,'Cashier')`, cashierRoleID, tenantID); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		t.Fatalf("seed cashier role: %v", err)
	}
	// The fixture already seeded an "Owner" role — fetch its real id.
	roles, err := svc.ListRoles(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list roles: %v", err)
	}
	for _, r := range roles {
		if r.Name == "Owner" {
			ownerRoleID = r.ID
		}
	}

	userID, err := svc.CreateUser(context.Background(), tenantID, identity.CreateUserInput{
		Username: "roletest_" + uuid.NewString()[:8], Password: "a-strong-password", DisplayName: "Role Test User",
		RoleIDs: []uuid.UUID{ownerRoleID},
	})
	if err != nil {
		t.Fatalf("create user: %v", err)
	}

	if err := svc.SetUserRoles(context.Background(), tenantID, userID, []uuid.UUID{cashierRoleID}); err != nil {
		t.Fatalf("set user roles: %v", err)
	}

	detail, err := svc.GetUserDetail(context.Background(), tenantID, userID)
	if err != nil {
		t.Fatalf("get user detail: %v", err)
	}
	if len(detail.RoleIDs) != 1 || detail.RoleIDs[0] != cashierRoleID {
		t.Fatalf("expected only the Cashier role after replacement, got %+v", detail.RoleIDs)
	}

	if err := svc.SetUserRoles(context.Background(), tenantID, userID, nil); err != nil {
		t.Fatalf("clear all roles: %v", err)
	}
	detail, err = svc.GetUserDetail(context.Background(), tenantID, userID)
	if err != nil {
		t.Fatalf("get user detail after clearing: %v", err)
	}
	if len(detail.RoleIDs) != 0 {
		t.Fatalf("expected no roles after clearing, got %+v", detail.RoleIDs)
	}
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
		// A client that restores a session purely via refresh (e.g. after an
		// app restart, without re-prompting for a password) must still see
		// the user's display name and permissions — otherwise every
		// permission-gated UI feature silently disappears despite the
		// user's role being unchanged.
		if result.DisplayName != "Test User" {
			t.Fatalf("expected refresh to carry the display name, got %q", result.DisplayName)
		}
		if len(result.Permissions) == 0 {
			t.Fatal("expected refresh to carry the user's permissions")
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
