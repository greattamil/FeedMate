//go:build integration

package devicepairing_test

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
	"github.com/andipatti/feedmate/services/api/internal/domain/devicepairing"
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

func seedTenant(t *testing.T, db *dbctx.DB) (tenantID, userID uuid.UUID) {
	t.Helper()
	tenantID = uuid.New()
	userID = uuid.New()
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		ctx := context.Background()
		if _, err := tx.Exec(ctx, `INSERT INTO tenants (id, legal_name, address_line1, city, state_code) VALUES ($1,'Pairing Test Tenant','1 St','Town','TN')`, tenantID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tenantID.String()); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO users (id, tenant_id, username, password_hash, display_name, status) VALUES ($1,$2,'owner','x','Owner','ACTIVE')`, userID, tenantID); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		t.Fatalf("seed tenant: %v", err)
	}
	t.Cleanup(func() {
		_ = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
			_, err := tx.Exec(context.Background(), `DELETE FROM tenants WHERE id = $1`, tenantID)
			return err
		})
	})
	return tenantID, userID
}

func TestDevicePairing_GenerateAndRedeem(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID, userID := seedTenant(t, db)
	svc := devicepairing.NewService(db)

	genResult, err := svc.GeneratePairingCode(context.Background(), tenantID, userID)
	if err != nil {
		t.Fatalf("generate pairing code: %v", err)
	}
	if len(genResult.Code) != 8 {
		t.Fatalf("expected an 8-character code, got %q", genResult.Code)
	}

	deviceUUID := uuid.New()
	regResult, err := svc.RegisterDevice(context.Background(), genResult.Code, deviceUUID, "Test Tablet", "ANDROID")
	if err != nil {
		t.Fatalf("register device: %v", err)
	}
	if regResult.TenantID != tenantID {
		t.Fatalf("expected tenant %s, got %s", tenantID, regResult.TenantID)
	}

	var status string
	err = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT status FROM devices WHERE tenant_id = $1 AND device_uuid = $2`, tenantID, deviceUUID).Scan(&status)
	})
	if err != nil {
		t.Fatalf("read device: %v", err)
	}
	if status != "ACTIVE" {
		t.Fatalf("expected device status ACTIVE, got %s", status)
	}
}

func TestDevicePairing_CodeCannotBeReusedAfterRedemption(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID, userID := seedTenant(t, db)
	svc := devicepairing.NewService(db)

	genResult, err := svc.GeneratePairingCode(context.Background(), tenantID, userID)
	if err != nil {
		t.Fatalf("generate pairing code: %v", err)
	}

	if _, err := svc.RegisterDevice(context.Background(), genResult.Code, uuid.New(), "Device A", "ANDROID"); err != nil {
		t.Fatalf("first registration: %v", err)
	}

	_, err = svc.RegisterDevice(context.Background(), genResult.Code, uuid.New(), "Device B", "ANDROID")
	if !errors.Is(err, devicepairing.ErrCodeInvalid) {
		t.Fatalf("expected ErrCodeInvalid on reuse, got: %v", err)
	}
}

func TestDevicePairing_UnknownCodeRejected(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	svc := devicepairing.NewService(db)

	_, err := svc.RegisterDevice(context.Background(), "ZZZZZZZZ", uuid.New(), "Rogue Device", "ANDROID")
	if !errors.Is(err, devicepairing.ErrCodeInvalid) {
		t.Fatalf("expected ErrCodeInvalid for an unknown code, got: %v", err)
	}
}

func TestDevicePairing_ExpiredCodeRejected(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID, userID := seedTenant(t, db)
	svc := devicepairing.NewService(db)

	// Insert an already-expired code directly rather than waiting the real TTL
	// out. Derived from a fresh UUID (not a fixed literal) so this can never
	// collide with a leftover row from a prior run — the `code` column is
	// globally unique across all tenants, and test tenant cleanup uses a
	// best-effort DELETE that is known to silently no-op when child rows
	// exist without ON DELETE CASCADE (see docs/IMPLEMENTATION_STATUS.md),
	// so a fixed literal here WILL eventually collide with orphaned data.
	expiredCode := strings.ToUpper("EXP" + uuid.NewString()[:5])
	err := db.WithTenantTx(context.Background(), tenantID, func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(), `
			INSERT INTO device_pairing_codes (tenant_id, code, created_by_user_id, expires_at)
			VALUES ($1, $2, $3, now() - interval '1 minute')
		`, tenantID, expiredCode, userID)
		return err
	})
	if err != nil {
		t.Fatalf("seed expired code: %v", err)
	}

	_, err = svc.RegisterDevice(context.Background(), expiredCode, uuid.New(), "Late Device", "ANDROID")
	if !errors.Is(err, devicepairing.ErrCodeInvalid) {
		t.Fatalf("expected ErrCodeInvalid for an expired code, got: %v", err)
	}
}

func TestDevicePairing_ConcurrentRedemptionOnlyOneSucceeds(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID, userID := seedTenant(t, db)
	svc := devicepairing.NewService(db)

	genResult, err := svc.GeneratePairingCode(context.Background(), tenantID, userID)
	if err != nil {
		t.Fatalf("generate pairing code: %v", err)
	}

	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		go func() {
			_, err := svc.RegisterDevice(context.Background(), genResult.Code, uuid.New(), "Racing Device", "ANDROID")
			results <- err
		}()
	}

	successCount := 0
	for i := 0; i < 2; i++ {
		if err := <-results; err == nil {
			successCount++
		} else if !errors.Is(err, devicepairing.ErrCodeInvalid) {
			t.Fatalf("unexpected error from concurrent redemption: %v", err)
		}
	}
	if successCount != 1 {
		t.Fatalf("expected exactly 1 of 2 concurrent redemptions to succeed, got %d", successCount)
	}
}
