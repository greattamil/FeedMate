//go:build integration

// Integration tests against a real, migrated PostgreSQL database. Run with:
//
//	go test -tags=integration ./internal/domain/masterdata/...
//
// Requires DATABASE_URL (app_user) and DATABASE_ADMIN_URL (app_admin).
package masterdata_test

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

func TestCreateCategory_AndDeactivate(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := masterdata.NewService(db)

	created, err := svc.CreateCategory(context.Background(), tenantID, "Poultry Feed", "கோழி தீவனம்")
	if err != nil {
		t.Fatalf("create category: %v", err)
	}
	if created.Name != "Poultry Feed" {
		t.Fatalf("expected name 'Poultry Feed', got %q", created.Name)
	}

	categories, err := svc.ListCategories(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list categories: %v", err)
	}
	if len(categories) != 1 || categories[0].ID != created.ID {
		t.Fatalf("expected the newly created category to be listed, got %+v", categories)
	}

	if _, err := svc.CreateCategory(context.Background(), tenantID, "", ""); !errors.Is(err, masterdata.ErrValidation) {
		t.Fatalf("expected ErrValidation for an empty name, got: %v", err)
	}

	if err := svc.SetCategoryActive(context.Background(), tenantID, created.ID, false); err != nil {
		t.Fatalf("deactivate category: %v", err)
	}
	afterDeactivate, err := svc.ListCategories(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list categories after deactivate: %v", err)
	}
	if len(afterDeactivate) != 0 {
		t.Fatalf("expected the deactivated category to be excluded from the active-only list, got %+v", afterDeactivate)
	}

	if err := svc.SetCategoryActive(context.Background(), tenantID, uuid.New(), true); !errors.Is(err, masterdata.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a nonexistent category, got: %v", err)
	}
}

// TestUpdateCategory_RenamesInPlace covers the "full CRUD" gap: previously
// the only way to fix a typo in a category name was deactivate-and-recreate,
// losing the original id every existing product still points to.
func TestUpdateCategory_RenamesInPlace(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := masterdata.NewService(db)

	created, err := svc.CreateCategory(context.Background(), tenantID, "Catle Feed", "")
	if err != nil {
		t.Fatalf("create category: %v", err)
	}

	if err := svc.UpdateCategory(context.Background(), tenantID, created.ID, "Cattle Feed", "மாட்டு தீவனம்"); err != nil {
		t.Fatalf("update category: %v", err)
	}

	categories, err := svc.ListAllCategories(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list categories: %v", err)
	}
	if len(categories) != 1 || categories[0].ID != created.ID || categories[0].Name != "Cattle Feed" || categories[0].LocalName != "மாட்டு தீவனம்" {
		t.Fatalf("expected the renamed category with the same id, got %+v", categories)
	}

	if err := svc.UpdateCategory(context.Background(), tenantID, created.ID, "", ""); !errors.Is(err, masterdata.ErrValidation) {
		t.Fatalf("expected ErrValidation for an empty name, got: %v", err)
	}
	if err := svc.UpdateCategory(context.Background(), tenantID, uuid.New(), "X", ""); !errors.Is(err, masterdata.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a nonexistent category, got: %v", err)
	}

	// ListAllCategories must include a since-deactivated row too.
	if err := svc.SetCategoryActive(context.Background(), tenantID, created.ID, false); err != nil {
		t.Fatalf("deactivate category: %v", err)
	}
	all, err := svc.ListAllCategories(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list all categories: %v", err)
	}
	if len(all) != 1 || all[0].Active {
		t.Fatalf("expected ListAllCategories to still include the deactivated category, got %+v", all)
	}
}

func TestCreateBrand_AndDeactivate(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := masterdata.NewService(db)

	created, err := svc.CreateBrand(context.Background(), tenantID, "Godrej Agrovet", "")
	if err != nil {
		t.Fatalf("create brand: %v", err)
	}

	brands, err := svc.ListBrands(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list brands: %v", err)
	}
	if len(brands) != 1 || brands[0].ID != created.ID {
		t.Fatalf("expected the newly created brand to be listed, got %+v", brands)
	}

	if err := svc.SetBrandActive(context.Background(), tenantID, created.ID, false); err != nil {
		t.Fatalf("deactivate brand: %v", err)
	}
	afterDeactivate, err := svc.ListBrands(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list brands after deactivate: %v", err)
	}
	if len(afterDeactivate) != 0 {
		t.Fatalf("expected the deactivated brand to be excluded from the active-only list, got %+v", afterDeactivate)
	}
}

// TestUpdateBrand_RenamesInPlace mirrors TestUpdateCategory_RenamesInPlace.
func TestUpdateBrand_RenamesInPlace(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := masterdata.NewService(db)

	created, err := svc.CreateBrand(context.Background(), tenantID, "Godrej Agro", "")
	if err != nil {
		t.Fatalf("create brand: %v", err)
	}

	if err := svc.UpdateBrand(context.Background(), tenantID, created.ID, "Godrej Agrovet", ""); err != nil {
		t.Fatalf("update brand: %v", err)
	}

	brands, err := svc.ListBrands(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list brands: %v", err)
	}
	if len(brands) != 1 || brands[0].ID != created.ID || brands[0].Name != "Godrej Agrovet" {
		t.Fatalf("expected the renamed brand with the same id, got %+v", brands)
	}

	if err := svc.UpdateBrand(context.Background(), tenantID, uuid.New(), "X", ""); !errors.Is(err, masterdata.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a nonexistent brand, got: %v", err)
	}
}

// TestCreateTaxProfile_UpdateAndDeactivate verifies the "central control"
// requested for GST-inclusive vs GST-exclusive product pricing: a shop
// owner can create two profiles at the same rate that differ only in
// PriceInclusive, edit one afterwards, and deactivate it without deleting
// it (existing products/invoices may still reference it by id).
func TestCreateTaxProfile_UpdateAndDeactivate(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID := seedTenant(t, db)
	svc := masterdata.NewService(db)

	rate9 := decimal.RequireFromString("9.00")
	zero := decimal.Zero

	exclusive, err := svc.CreateTaxProfile(context.Background(), tenantID, "GST18-EXCL", "GST 18% (exclusive)", "INTRA_STATE", rate9, rate9, zero, zero, false)
	if err != nil {
		t.Fatalf("create exclusive tax profile: %v", err)
	}
	if exclusive.PriceInclusive {
		t.Fatalf("expected the exclusive profile to have PriceInclusive=false")
	}

	inclusive, err := svc.CreateTaxProfile(context.Background(), tenantID, "GST18-INCL", "GST 18% (inclusive)", "INTRA_STATE", rate9, rate9, zero, zero, true)
	if err != nil {
		t.Fatalf("create inclusive tax profile: %v", err)
	}
	if !inclusive.PriceInclusive {
		t.Fatalf("expected the inclusive profile to have PriceInclusive=true")
	}

	profiles, err := svc.ListTaxProfiles(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list tax profiles: %v", err)
	}
	if len(profiles) != 2 {
		t.Fatalf("expected both profiles to be listed, got %+v", profiles)
	}

	if _, err := svc.CreateTaxProfile(context.Background(), tenantID, "BAD", "", "INTRA_STATE", zero, zero, zero, zero, false); !errors.Is(err, masterdata.ErrValidation) {
		t.Fatalf("expected ErrValidation for an empty description, got: %v", err)
	}
	if _, err := svc.CreateTaxProfile(context.Background(), tenantID, "BAD2", "desc", "NOT_A_REAL_TYPE", zero, zero, zero, zero, false); !errors.Is(err, masterdata.ErrValidation) {
		t.Fatalf("expected ErrValidation for an invalid supply_type, got: %v", err)
	}

	newRate := decimal.RequireFromString("14.00")
	if err := svc.UpdateTaxProfile(context.Background(), tenantID, inclusive.ID, "GST 28% (inclusive, updated)", "INTRA_STATE", newRate, newRate, zero, zero, true); err != nil {
		t.Fatalf("update tax profile: %v", err)
	}
	updated, err := svc.ListTaxProfiles(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list after update: %v", err)
	}
	var found *masterdata.TaxProfile
	for i := range updated {
		if updated[i].ID == inclusive.ID {
			found = &updated[i]
		}
	}
	if found == nil || !found.CGSTRate.Equal(newRate) || found.Description != "GST 28% (inclusive, updated)" {
		t.Fatalf("expected the update to take effect, got %+v", found)
	}

	if err := svc.UpdateTaxProfile(context.Background(), tenantID, uuid.New(), "x", "INTRA_STATE", zero, zero, zero, zero, false); !errors.Is(err, masterdata.ErrNotFound) {
		t.Fatalf("expected ErrNotFound updating a nonexistent tax profile, got: %v", err)
	}

	if err := svc.SetTaxProfileActive(context.Background(), tenantID, exclusive.ID, false); err != nil {
		t.Fatalf("deactivate tax profile: %v", err)
	}
	afterDeactivate, err := svc.ListTaxProfiles(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list after deactivate: %v", err)
	}
	if len(afterDeactivate) != 1 {
		t.Fatalf("expected the deactivated profile excluded from the active-only list, got %+v", afterDeactivate)
	}

	allIncludingInactive, err := svc.ListAllTaxProfiles(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list all tax profiles: %v", err)
	}
	if len(allIncludingInactive) != 2 {
		t.Fatalf("expected ListAllTaxProfiles to still include the deactivated profile, got %+v", allIncludingInactive)
	}
}
