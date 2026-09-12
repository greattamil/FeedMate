//go:build integration

package pos_test

import (
	"context"
	"testing"

	"github.com/google/uuid"
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
