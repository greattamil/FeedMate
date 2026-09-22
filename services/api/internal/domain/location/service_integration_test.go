//go:build integration

// Integration tests against a real, migrated PostgreSQL database. Run with:
//
//	go test -tags=integration ./internal/domain/location/...
//
// Requires DATABASE_URL (app_user) and DATABASE_ADMIN_URL (app_admin).
package location_test

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/location"
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
		_, err := tx.Exec(context.Background(),
			`INSERT INTO tenants (id, legal_name, address_line1, city, state_code) VALUES ($1,'Location Test Tenant','1 Test St','Testville','TN')`,
			tenantID)
		return err
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
	return tenantID
}

// TestLocationCRUD covers the gap that previously left a brand-new tenant
// with zero locations and no way to add one — GRN, POS, and stock-count
// screens all depend on at least one active location existing.
func TestLocationCRUD(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := location.NewService(db)

	created, err := svc.Create(context.Background(), tenantID, "MAIN", "Main Godown", "GODOWN")
	if err != nil {
		t.Fatalf("create location: %v", err)
	}
	if created.Code != "MAIN" || created.Name != "Main Godown" || created.Type != "GODOWN" || !created.Active {
		t.Fatalf("unexpected created location: %+v", created)
	}

	active, err := svc.ListActive(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list active: %v", err)
	}
	if len(active) != 1 || active[0].ID != created.ID {
		t.Fatalf("expected the newly created location to be listed, got %+v", active)
	}

	if _, err := svc.Create(context.Background(), tenantID, "", "No Code", "GODOWN"); !errors.Is(err, location.ErrValidation) {
		t.Fatalf("expected ErrValidation for an empty code, got: %v", err)
	}
	if _, err := svc.Create(context.Background(), tenantID, "BAD", "Bad Type", "WAREHOUSE"); !errors.Is(err, location.ErrValidation) {
		t.Fatalf("expected ErrValidation for an invalid location_type, got: %v", err)
	}

	if err := svc.Update(context.Background(), tenantID, created.ID, "Main Godown (Renamed)", "SHOP"); err != nil {
		t.Fatalf("update location: %v", err)
	}
	afterUpdate, err := svc.ListActive(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list active after update: %v", err)
	}
	if len(afterUpdate) != 1 || afterUpdate[0].Name != "Main Godown (Renamed)" || afterUpdate[0].Type != "SHOP" || afterUpdate[0].Code != "MAIN" {
		t.Fatalf("expected the renamed location with an unchanged code, got %+v", afterUpdate)
	}
	if err := svc.Update(context.Background(), tenantID, uuid.New(), "X", "SHOP"); !errors.Is(err, location.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a nonexistent location, got: %v", err)
	}

	if err := svc.SetActive(context.Background(), tenantID, created.ID, false); err != nil {
		t.Fatalf("deactivate location: %v", err)
	}
	afterDeactivate, err := svc.ListActive(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list active after deactivate: %v", err)
	}
	if len(afterDeactivate) != 0 {
		t.Fatalf("expected the deactivated location excluded from the active-only list, got %+v", afterDeactivate)
	}

	all, err := svc.ListAll(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list all: %v", err)
	}
	if len(all) != 1 || all[0].Active {
		t.Fatalf("expected ListAll to still include the deactivated location, got %+v", all)
	}

	if err := svc.SetActive(context.Background(), tenantID, uuid.New(), true); !errors.Is(err, location.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a nonexistent location, got: %v", err)
	}
}
