//go:build integration

// Integration tests against a real, migrated PostgreSQL database. Run with:
//   go test -tags=integration ./internal/domain/product/...
// Requires DATABASE_URL (app_user) and DATABASE_ADMIN_URL (app_admin).
package product_test

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/product"
)

func mustEnv(t *testing.T, key string) string {
	t.Helper()
	v := os.Getenv(key)
	if v == "" {
		t.Skipf("%s not set; skipping integration test", key)
	}
	return v
}

// Standard global UOM IDs seeded by db/migrations/0013_seed_reference_data.up.sql.
var (
	uomKG  = uuid.MustParse("00000000-0000-0000-0000-000000000101")
	uomBag = uuid.MustParse("00000000-0000-0000-0000-000000000104")
)

func seedTenant(t *testing.T, db *dbctx.DB) uuid.UUID {
	t.Helper()
	tenantID := uuid.New()
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(),
			`INSERT INTO tenants (id, legal_name, address_line1, city, state_code) VALUES ($1,'Product Test Tenant','1 Test St','Testville','TN')`,
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

func TestProductCreateAndSearch(t *testing.T) {
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
	svc := product.NewService(db)

	mrp := decimal.RequireFromString("1250.00")
	sellingPrice := decimal.RequireFromString("1200.00")
	sku := "CF-" + uuid.NewString()[:8]
	barcode := "890" + uuid.NewString()[:10]

	created, err := svc.Create(context.Background(), tenantID, product.CreateInput{
		Product: product.Product{
			SKU:                  sku,
			Name:                 "Cattle Feed Premium 50kg",
			DefaultSaleUOMID:     uomBag,
			DefaultPurchaseUOMID: uomBag,
			BaseInventoryUOMID:   uomKG,
			MRP:                  &mrp,
			SellingPrice:         &sellingPrice,
			BatchRequired:        true,
			ExpiryRequired:       true,
		},
		Barcodes: []string{barcode},
		Aliases:  []string{"mattu theevanam"},
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	// Regression guard: Create() must return the true persisted state (e.g.
	// active=true from the DB default), not Go zero-values for columns the
	// INSERT didn't set explicitly — this was a real bug found in manual
	// testing before this test existed.
	if !created.Active {
		t.Fatal("expected newly created product to be active (DB default), got Active=false in the returned struct")
	}

	fetched, err := svc.GetByID(context.Background(), tenantID, created.ID)
	if err != nil {
		t.Fatalf("get by id: %v", err)
	}
	if fetched.SKU != sku || !fetched.Active {
		t.Fatalf("fetched product mismatch: %+v", fetched)
	}

	t.Run("exact barcode match ranks first", func(t *testing.T) {
		results, err := svc.Search(context.Background(), tenantID, barcode, 10)
		if err != nil {
			t.Fatalf("search: %v", err)
		}
		if len(results) == 0 || results[0].MatchType != "BARCODE" || results[0].Product.ID != created.ID {
			t.Fatalf("expected barcode match first, got %+v", results)
		}
	})

	t.Run("exact SKU match is found despite hyphens", func(t *testing.T) {
		// Regression guard: normalizing the query before SKU matching used to
		// strip hyphens (e.g. "CF-50KG-002" -> "cf50kg002"), silently breaking
		// every exact SKU lookup. Found via manual testing before this test
		// existed; fixed by matching SKU/barcode against the raw query and
		// only using the normalized form for name/alias/fuzzy matching.
		results, err := svc.Search(context.Background(), tenantID, sku, 10)
		if err != nil {
			t.Fatalf("search: %v", err)
		}
		if len(results) == 0 || results[0].MatchType != "SKU" || results[0].Product.ID != created.ID {
			t.Fatalf("expected SKU match first, got %+v", results)
		}
	})

	t.Run("transliterated alias resolves to the product, canonical name unchanged", func(t *testing.T) {
		results, err := svc.Search(context.Background(), tenantID, "MATTU THEEVANAM", 10)
		if err != nil {
			t.Fatalf("search: %v", err)
		}
		found := false
		for _, r := range results {
			if r.Product.ID == created.ID {
				found = true
				if r.Product.Name != "Cattle Feed Premium 50kg" {
					t.Fatalf("canonical name must not change due to alias match, got %q", r.Product.Name)
				}
			}
		}
		if !found {
			t.Fatalf("expected alias search to resolve to seeded product, got %+v", results)
		}
	})

	t.Run("no match returns empty results, not an error", func(t *testing.T) {
		results, err := svc.Search(context.Background(), tenantID, "zzz_definitely_not_present_9999", 10)
		if err != nil {
			t.Fatalf("search: %v", err)
		}
		if len(results) != 0 {
			t.Fatalf("expected no results, got %+v", results)
		}
	})
}
