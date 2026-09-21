//go:build integration

package pos_test

import (
	"context"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/domain/pos"
)

func TestQuote_MatchesWhatFinalizeWouldCharge(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	svc := pos.NewService(db)

	lines := []pos.SaleLine{{ProductID: f.productID, Quantity: decimal.RequireFromString("3")}}

	quote, err := svc.Quote(context.Background(), f.tenantID, lines)
	if err != nil {
		t.Fatalf("quote: %v", err)
	}
	// 3 bags * 1200 = 3600 taxable; 5% GST = 180; grand total 3780 — must match
	// the exact figures TestFinalizeInvoice_CashSale verifies FinalizeInvoice
	// actually charges for the identical cart, proving Quote and
	// FinalizeInvoice share one pricing implementation rather than two that
	// could silently drift apart.
	if !quote.TaxableTotal.Equal(decimal.RequireFromString("3600.00")) {
		t.Fatalf("expected taxable total 3600.00, got %s", quote.TaxableTotal)
	}
	if !quote.TaxTotal.Equal(decimal.RequireFromString("180.00")) {
		t.Fatalf("expected tax total 180.00, got %s", quote.TaxTotal)
	}
	if !quote.GrandTotal.Equal(decimal.RequireFromString("3780.00")) {
		t.Fatalf("expected grand total 3780.00, got %s", quote.GrandTotal)
	}

	// Quote must not touch stock or write anything.
	if got := availableQty(t, db, f); !got.Equal(f.initialQty) {
		t.Fatalf("Quote must not change stock, got %s (expected %s)", got, f.initialQty)
	}

	// Finalizing the exact same cart with the quoted grand total as the tender
	// must succeed — proving the quoted total really is what the server will
	// charge, not just a plausible-looking number.
	result, err := svc.FinalizeInvoice(context.Background(), f.tenantID, f.deviceID, f.userID, pos.FinalizeRequest{
		ClientTransactionID: uuid.New(),
		LocationID:          f.locationID,
		Lines:               lines,
		Tenders:             []pos.Tender{{Method: "CASH", Amount: quote.GrandTotal}},
	})
	if err != nil {
		t.Fatalf("finalize using the quoted total: %v", err)
	}
	if !result.GrandTotal.Equal(quote.GrandTotal) {
		t.Fatalf("finalized grand total %s did not match quoted total %s", result.GrandTotal, quote.GrandTotal)
	}
}

// TestQuote_PriceInclusiveTaxProfileBacksTaxOutOfTheSellingPrice is the
// regression test for the "central control" GST-inclusive/exclusive
// pricing feature: a product whose tax profile has price_inclusive=true
// must never be charged more than its configured selling price — the tax
// is backed out of that price, not added on top of it (which is what a
// price-exclusive product, and the pre-fix behavior, both do).
func TestQuote_PriceInclusiveTaxProfileBacksTaxOutOfTheSellingPrice(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	svc := pos.NewService(db)

	inclusiveTaxProfileID := uuid.New()
	inclusiveProductID := uuid.New()
	// 9% CGST + 9% SGST = 18% total. A 118.00 inclusive selling price must
	// back out to exactly 100.00 taxable + 18.00 tax — chosen so the
	// division has no rounding ambiguity and the assertion is exact.
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		ctx := context.Background()
		if _, err := tx.Exec(ctx, `
			INSERT INTO tax_profiles (id, tenant_id, code, description, supply_type, cgst_rate, sgst_rate, price_inclusive, effective_from)
			VALUES ($1,$2,'GST18-INCL','GST 18% inclusive','INTRA_STATE',9,9,true,'2020-01-01')
		`, inclusiveTaxProfileID, f.tenantID); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `
			INSERT INTO products (id, tenant_id, sku, name, default_sale_uom_id, default_purchase_uom_id, base_inventory_uom_id, tax_profile_id, selling_price, batch_required, expiry_required)
			VALUES ($1,$2,$3,'Inclusive Priced Feed',$4,$4,$5,$6,'118.00',true,true)
		`, inclusiveProductID, f.tenantID, "SKU-INCL-"+uuid.NewString()[:8], uomBag, uomKG, inclusiveTaxProfileID)
		return err
	})
	if err != nil {
		t.Fatalf("seed inclusive-priced product: %v", err)
	}

	quote, err := svc.Quote(context.Background(), f.tenantID, []pos.SaleLine{{ProductID: inclusiveProductID, Quantity: decimal.RequireFromString("1")}})
	if err != nil {
		t.Fatalf("quote: %v", err)
	}
	if !quote.TaxableTotal.Equal(decimal.RequireFromString("100.00")) {
		t.Fatalf("expected taxable total 100.00 (backed out of the 118.00 inclusive price), got %s", quote.TaxableTotal)
	}
	if !quote.TaxTotal.Equal(decimal.RequireFromString("18.00")) {
		t.Fatalf("expected tax total 18.00, got %s", quote.TaxTotal)
	}
	// The customer must never be charged more than the configured selling
	// price — this is the whole point of "inclusive" pricing.
	if !quote.GrandTotal.Equal(decimal.RequireFromString("118.00")) {
		t.Fatalf("expected grand total to equal the configured inclusive price 118.00, got %s", quote.GrandTotal)
	}
}

func TestQuote_RejectsInactiveOrMissingProduct(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	f := seedFixture(t, db)
	svc := pos.NewService(db)
	_ = f

	_, err := svc.Quote(context.Background(), f.tenantID, []pos.SaleLine{{ProductID: uuid.New(), Quantity: decimal.RequireFromString("1")}})
	if err == nil {
		t.Fatal("expected an error for a nonexistent product")
	}
}
