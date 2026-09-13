//go:build integration

// Integration tests against a real, migrated PostgreSQL database. Run with:
//   go test -tags=integration ./internal/domain/masterdata/...
// Requires DATABASE_URL (app_user) and DATABASE_ADMIN_URL (app_admin).
package masterdata_test

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/masterdata"
)

func mustEnv(t *testing.T, key string) string {
	t.Helper()
	v := os.Getenv(key)
	if v == "" {
		t.Skipf("%s not set; skipping integration test", key)
	}
	return v
}

func seedTenant(t *testing.T, db *dbctx.DB) uuid.UUID {
	t.Helper()
	tenantID := uuid.New()
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(),
			`INSERT INTO tenants (id, legal_name, address_line1, city, state_code) VALUES ($1,'Masterdata Test Tenant','1 Test St','Testville','TN')`,
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

func TestMasterDataLists(t *testing.T) {
	dsn := mustEnv(t, "DATABASE_URL")
	adminDSN := mustEnv(t, "DATABASE_ADMIN_URL")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	db, err := dbctx.Connect(ctx, dsn, adminDSN)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer db.Close()

	tenantID := seedTenant(t, db)
	svc := masterdata.NewService(db)

	t.Run("ListUOMs returns the global seeded UOMs even for a brand-new tenant", func(t *testing.T) {
		uoms, err := svc.ListUOMs(context.Background(), tenantID)
		if err != nil {
			t.Fatalf("list uoms: %v", err)
		}
		if len(uoms) == 0 {
			t.Fatal("expected at least the globally-seeded UOMs (kg, bag, etc.)")
		}
		foundBag := false
		for _, u := range uoms {
			if u.Code == "BAG" {
				foundBag = true
			}
		}
		if !foundBag {
			t.Fatalf("expected the seeded BAG UOM to be visible, got %+v", uoms)
		}
	})

	t.Run("ListTaxProfiles, ListCategories, ListBrands succeed for a brand-new tenant with no rows", func(t *testing.T) {
		if _, err := svc.ListTaxProfiles(context.Background(), tenantID); err != nil {
			t.Fatalf("list tax profiles: %v", err)
		}
		categories, err := svc.ListCategories(context.Background(), tenantID)
		if err != nil {
			t.Fatalf("list categories: %v", err)
		}
		if len(categories) != 0 {
			t.Fatalf("expected no categories for a brand-new tenant, got %+v", categories)
		}
		brands, err := svc.ListBrands(context.Background(), tenantID)
		if err != nil {
			t.Fatalf("list brands: %v", err)
		}
		if len(brands) != 0 {
			t.Fatalf("expected no brands for a brand-new tenant, got %+v", brands)
		}
	})

	t.Run("a category created for one tenant is invisible to another (RLS)", func(t *testing.T) {
		otherTenantID := seedTenant(t, db)
		if err := db.WithTenantTx(context.Background(), tenantID, func(tx pgx.Tx) error {
			_, err := tx.Exec(context.Background(), `INSERT INTO categories (tenant_id, name) VALUES ($1, 'Cattle Feed')`, tenantID)
			return err
		}); err != nil {
			t.Fatalf("seed category: %v", err)
		}

		ownCategories, err := svc.ListCategories(context.Background(), tenantID)
		if err != nil {
			t.Fatalf("list own categories: %v", err)
		}
		if len(ownCategories) != 1 || ownCategories[0].Name != "Cattle Feed" {
			t.Fatalf("expected exactly the seeded category, got %+v", ownCategories)
		}

		otherCategories, err := svc.ListCategories(context.Background(), otherTenantID)
		if err != nil {
			t.Fatalf("list other tenant's categories: %v", err)
		}
		if len(otherCategories) != 0 {
			t.Fatalf("expected tenant isolation to hide the other tenant's category, got %+v", otherCategories)
		}
	})
}
