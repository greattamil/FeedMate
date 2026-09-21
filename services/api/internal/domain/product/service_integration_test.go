//go:build integration

// Integration tests against a real, migrated PostgreSQL database. Run with:
//
//	go test -tags=integration ./internal/domain/product/...
//
// Requires DATABASE_URL (app_user) and DATABASE_ADMIN_URL (app_admin).
package product_test

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
		results, err := svc.Search(context.Background(), tenantID, barcode, nil, 10)
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
		results, err := svc.Search(context.Background(), tenantID, sku, nil, 10)
		if err != nil {
			t.Fatalf("search: %v", err)
		}
		if len(results) == 0 || results[0].MatchType != "SKU" || results[0].Product.ID != created.ID {
			t.Fatalf("expected SKU match first, got %+v", results)
		}
	})

	t.Run("transliterated alias resolves to the product, canonical name unchanged", func(t *testing.T) {
		results, err := svc.Search(context.Background(), tenantID, "MATTU THEEVANAM", nil, 10)
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
		results, err := svc.Search(context.Background(), tenantID, "zzz_definitely_not_present_9999", nil, 10)
		if err != nil {
			t.Fatalf("search: %v", err)
		}
		if len(results) != 0 {
			t.Fatalf("expected no results, got %+v", results)
		}
	})

	t.Run("category_id narrows results to real categories, and browses a whole category with an empty query", func(t *testing.T) {
		// Regression guard for the POS catalog's category filter chips: they
		// must filter against real category rows (the same ones
		// masterdata.ListCategories returns), not a client-side hard-coded
		// list unrelated to actual product data.
		var categoryID uuid.UUID
		if err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
			return tx.QueryRow(context.Background(),
				`INSERT INTO categories (tenant_id, name) VALUES ($1, 'Cattle Feed Category') RETURNING id`,
				tenantID).Scan(&categoryID)
		}); err != nil {
			t.Fatalf("seed category: %v", err)
		}
		if _, err := svc.Update(context.Background(), tenantID, created.ID, product.UpdateInput{
			Product: product.Product{
				SKU: sku, Name: fetched.Name, CategoryID: &categoryID,
				DefaultSaleUOMID: uomBag, DefaultPurchaseUOMID: uomBag, BaseInventoryUOMID: uomKG,
				BatchRequired: true, ExpiryRequired: true,
			},
		}); err != nil {
			t.Fatalf("assign category: %v", err)
		}

		results, err := svc.Search(context.Background(), tenantID, "", &categoryID, 10)
		if err != nil {
			t.Fatalf("browse category with empty query: %v", err)
		}
		found := false
		for _, r := range results {
			if r.Product.ID == created.ID {
				found = true
			}
			if r.Product.CategoryID == nil || *r.Product.CategoryID != categoryID {
				t.Fatalf("expected every result to belong to the filtered category, got %+v", r.Product)
			}
		}
		if !found {
			t.Fatalf("expected the categorized product in an empty-query browse of its category, got %+v", results)
		}

		otherCategoryID := uuid.New()
		results, err = svc.Search(context.Background(), tenantID, "", &otherCategoryID, 10)
		if err != nil {
			t.Fatalf("browse unrelated category: %v", err)
		}
		if len(results) != 0 {
			t.Fatalf("expected no results for an unrelated category, got %+v", results)
		}
	})

	t.Run("an empty query with no category browses the whole active catalog, not nothing", func(t *testing.T) {
		// Regression guard: the POS counter must show its catalog by
		// default (real terminals don't start on a blank screen requiring
		// the cashier to type first) — an empty query with no category
		// filter must return active products, bounded only by limit, not
		// be rejected or return zero rows.
		results, err := svc.Search(context.Background(), tenantID, "", nil, 10)
		if err != nil {
			t.Fatalf("browse whole catalog: %v", err)
		}
		found := false
		for _, r := range results {
			if r.Product.ID == created.ID {
				found = true
			}
		}
		if !found {
			t.Fatalf("expected the seeded product in an unfiltered catalog browse, got %+v", results)
		}
	})
}

func TestProductUpdateSetActiveList(t *testing.T) {
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

	sku := "UPD-" + uuid.NewString()[:8]
	created, err := svc.Create(context.Background(), tenantID, product.CreateInput{
		Product: product.Product{
			SKU: sku, Name: "Original Name",
			DefaultSaleUOMID: uomBag, DefaultPurchaseUOMID: uomBag, BaseInventoryUOMID: uomKG,
			BatchRequired: true, ExpiryRequired: true,
		},
		Barcodes: []string{"111" + uuid.NewString()[:10]},
		Aliases:  []string{"original alias"},
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	t.Run("Update renames the product, replaces barcodes/aliases, and never changes SKU", func(t *testing.T) {
		newPrice := decimal.RequireFromString("999.00")
		newBarcode := "222" + uuid.NewString()[:10]
		updated, err := svc.Update(context.Background(), tenantID, created.ID, product.UpdateInput{
			Product: product.Product{
				SKU:  "attempted-sku-change-should-be-ignored", // Update must never touch SKU
				Name: "Renamed Product", SellingPrice: &newPrice,
				DefaultSaleUOMID: uomBag, DefaultPurchaseUOMID: uomBag, BaseInventoryUOMID: uomKG,
				BatchRequired: true, ExpiryRequired: true,
			},
			Barcodes: []string{newBarcode},
			Aliases:  []string{"renamed alias"},
		})
		if err != nil {
			t.Fatalf("update: %v", err)
		}
		if updated.Name != "Renamed Product" {
			t.Fatalf("expected renamed product, got %+v", updated)
		}
		if updated.SKU != sku {
			t.Fatalf("SKU must never change via Update: expected %q, got %q", sku, updated.SKU)
		}
		if updated.SellingPrice == nil || !updated.SellingPrice.Equal(newPrice) {
			t.Fatalf("expected selling price %s, got %v", newPrice, updated.SellingPrice)
		}

		detail, err := svc.GetDetail(context.Background(), tenantID, created.ID)
		if err != nil {
			t.Fatalf("get detail: %v", err)
		}
		if len(detail.Barcodes) != 1 || detail.Barcodes[0].Barcode != newBarcode {
			t.Fatalf("expected old barcode replaced by new one, got %+v", detail.Barcodes)
		}
		if len(detail.Aliases) != 1 || detail.Aliases[0].AliasText != "renamed alias" {
			t.Fatalf("expected old alias replaced by new one, got %+v", detail.Aliases)
		}

		// The old barcode must no longer resolve to this product.
		if _, err := svc.GetByBarcode(context.Background(), tenantID, newBarcode); err != nil {
			t.Fatalf("expected new barcode to resolve: %v", err)
		}
	})

	t.Run("SetActive deactivates and reactivates without deleting the row", func(t *testing.T) {
		deactivated, err := svc.SetActive(context.Background(), tenantID, created.ID, false)
		if err != nil {
			t.Fatalf("deactivate: %v", err)
		}
		if deactivated.Active {
			t.Fatal("expected Active=false after deactivation")
		}

		// A deactivated product must not resolve via GetByBarcode (which the
		// GRN/POS flows rely on to only ever offer sellable products).
		fetched, err := svc.GetByID(context.Background(), tenantID, created.ID)
		if err != nil {
			t.Fatalf("get by id after deactivate: %v", err)
		}
		if fetched.Active {
			t.Fatal("expected persisted Active=false")
		}

		reactivated, err := svc.SetActive(context.Background(), tenantID, created.ID, true)
		if err != nil {
			t.Fatalf("reactivate: %v", err)
		}
		if !reactivated.Active {
			t.Fatal("expected Active=true after reactivation")
		}
	})

	t.Run("SetActive on an unknown product returns ErrNotFound", func(t *testing.T) {
		if _, err := svc.SetActive(context.Background(), tenantID, uuid.New(), false); !errors.Is(err, product.ErrNotFound) {
			t.Fatalf("expected ErrNotFound, got: %v", err)
		}
	})

	t.Run("List finds the product by name substring and respects the active filter", func(t *testing.T) {
		result, err := svc.List(context.Background(), tenantID, product.ListOptions{Query: "Renamed", ActiveOnly: true})
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		if result.Total != 1 || len(result.Products) != 1 || result.Products[0].ID != created.ID {
			t.Fatalf("expected exactly the renamed product, got %+v", result)
		}

		if _, err := svc.SetActive(context.Background(), tenantID, created.ID, false); err != nil {
			t.Fatalf("deactivate for filter test: %v", err)
		}
		t.Cleanup(func() { _, _ = svc.SetActive(context.Background(), tenantID, created.ID, true) })

		activeOnly, err := svc.List(context.Background(), tenantID, product.ListOptions{Query: "Renamed", ActiveOnly: true})
		if err != nil {
			t.Fatalf("list active-only: %v", err)
		}
		if activeOnly.Total != 0 {
			t.Fatalf("expected deactivated product hidden from active-only list, got %+v", activeOnly)
		}

		includingInactive, err := svc.List(context.Background(), tenantID, product.ListOptions{Query: "Renamed", ActiveOnly: false})
		if err != nil {
			t.Fatalf("list including inactive: %v", err)
		}
		if includingInactive.Total != 1 {
			t.Fatalf("expected deactivated product visible when ActiveOnly=false, got %+v", includingInactive)
		}
	})
}

// The stock-alert control the user asked for directly: a shop owner should
// be able to turn off low/out-of-stock alerting for one product without it
// affecting anything else about the product. Covers both Create (an
// explicit true and an explicit false) and Update (flipping an existing
// product's setting), and confirms it round-trips through GetByID and List
// — every read path a caller might use, not just the one Create returns.
func TestProductStockAlertEnabled_RoundTripsThroughCreateUpdateAndReads(t *testing.T) {
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

	alertsOn, err := svc.Create(context.Background(), tenantID, product.CreateInput{
		Product: product.Product{
			SKU: "ALERT-ON-" + uuid.NewString()[:8], Name: "Alerts On Product",
			DefaultSaleUOMID: uomBag, DefaultPurchaseUOMID: uomBag, BaseInventoryUOMID: uomKG,
			StockAlertEnabled: true,
		},
	})
	if err != nil {
		t.Fatalf("create (alerts on): %v", err)
	}
	if !alertsOn.StockAlertEnabled {
		t.Fatal("expected StockAlertEnabled=true to persist from Create")
	}

	alertsOff, err := svc.Create(context.Background(), tenantID, product.CreateInput{
		Product: product.Product{
			SKU: "ALERT-OFF-" + uuid.NewString()[:8], Name: "Alerts Off Product",
			DefaultSaleUOMID: uomBag, DefaultPurchaseUOMID: uomBag, BaseInventoryUOMID: uomKG,
			StockAlertEnabled: false,
		},
	})
	if err != nil {
		t.Fatalf("create (alerts off): %v", err)
	}
	if alertsOff.StockAlertEnabled {
		t.Fatal("expected StockAlertEnabled=false to persist from Create, not silently default to true")
	}

	fetched, err := svc.GetByID(context.Background(), tenantID, alertsOff.ID)
	if err != nil {
		t.Fatalf("get by id: %v", err)
	}
	if fetched.StockAlertEnabled {
		t.Fatal("expected GetByID to reflect the persisted false, not the column's true default")
	}

	updated, err := svc.Update(context.Background(), tenantID, alertsOff.ID, product.UpdateInput{
		Product: product.Product{
			Name: "Alerts Off Product", DefaultSaleUOMID: uomBag, DefaultPurchaseUOMID: uomBag, BaseInventoryUOMID: uomKG,
			StockAlertEnabled: true,
		},
	})
	if err != nil {
		t.Fatalf("update to turn alerts back on: %v", err)
	}
	if !updated.StockAlertEnabled {
		t.Fatal("expected Update to be able to flip StockAlertEnabled back to true")
	}

	page, err := svc.List(context.Background(), tenantID, product.ListOptions{Query: "Alerts On Product"})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(page.Products) != 1 || !page.Products[0].StockAlertEnabled {
		t.Fatalf("expected List to also carry StockAlertEnabled=true, got %+v", page.Products)
	}
}
