package pos

import (
	"context"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/domain/product"
)

// pricedLine is the single authoritative pricing/tax computation for one
// cart line, shared by Quote (preview only) and FinalizeInvoice (commits).
// PRD 90 warns against a business rule existing in more than one place;
// this function is that one place for "what does this line cost, including
// tax" — Quote and FinalizeInvoice must never independently recompute it.
type pricedLine struct {
	product      *product.Product
	unitPrice    decimal.Decimal
	taxableValue decimal.Decimal
	taxProfile   *TaxProfile
	taxComps     []TaxComponent
	taxTotal     decimal.Decimal
	lineTotal    decimal.Decimal
}

func priceLine(ctx context.Context, tx pgx.Tx, line SaleLine) (*pricedLine, error) {
	if line.Quantity.LessThanOrEqual(decimal.Zero) {
		return nil, fmt.Errorf("%w: line quantity must be positive", ErrValidation)
	}
	p, err := product.GetByID(ctx, tx, line.ProductID)
	if err != nil {
		return nil, fmt.Errorf("load product %s: %w", line.ProductID, err)
	}
	if !p.Active {
		return nil, fmt.Errorf("%w: product %s is not active", ErrValidation, p.SKU)
	}

	unitPrice := p.SellingPrice
	if line.UnitPriceOverride != nil {
		unitPrice = line.UnitPriceOverride
	}
	if unitPrice == nil {
		return nil, fmt.Errorf("%w: product %s has no selling price configured", ErrValidation, p.SKU)
	}

	lineSubtotal := unitPrice.Mul(line.Quantity)
	taxableValue := lineSubtotal.Sub(line.DiscountAmount)
	if taxableValue.LessThan(decimal.Zero) {
		return nil, fmt.Errorf("%w: discount exceeds line subtotal for product %s", ErrValidation, p.SKU)
	}

	if p.TaxProfileID == nil {
		return nil, ErrNoTaxProfile
	}
	taxProfile, err := GetActiveTaxProfile(ctx, tx, *p.TaxProfileID)
	if err != nil {
		return nil, fmt.Errorf("tax profile for product %s: %w", p.SKU, err)
	}
	comps, lineTax := CalculateLineTax(taxProfile, taxableValue)

	return &pricedLine{
		product: p, unitPrice: *unitPrice, taxableValue: taxableValue,
		taxProfile: taxProfile, taxComps: comps, taxTotal: lineTax,
		lineTotal: taxableValue.Add(lineTax),
	}, nil
}

// QuoteLine is one priced-but-not-committed cart line: it shows the cashier
// exactly what FinalizeInvoice would charge for this product/quantity,
// without allocating stock, generating an invoice number, or writing
// anything. This lets the Flutter app display an accurate running total
// before checkout without re-implementing the server's tax calculation
// client-side — the server remains the sole source of pricing/tax truth
// (PRD A28), and a client-side duplicate would risk drifting out of sync
// with real tax-profile changes.
type QuoteLine struct {
	ProductID    uuid.UUID
	ProductName  string
	Quantity     decimal.Decimal
	UnitPrice    decimal.Decimal
	TaxableValue decimal.Decimal
	TaxTotal     decimal.Decimal
	LineTotal    decimal.Decimal
}

type QuoteResult struct {
	Lines        []QuoteLine
	TaxableTotal decimal.Decimal
	TaxTotal     decimal.Decimal
	GrandTotal   decimal.Decimal
}

// Quote computes pricing/tax for a prospective cart using priceLine — the
// exact same logic FinalizeInvoice uses — but performs no writes and no
// stock checks: stock sufficiency and the final authoritative total are
// only decided at FinalizeInvoice time, since stock can change between a
// quote and checkout.
func (s *Service) Quote(ctx context.Context, tenantID uuid.UUID, lines []SaleLine) (*QuoteResult, error) {
	if len(lines) == 0 {
		return nil, fmt.Errorf("%w: at least one line is required", ErrValidation)
	}

	var result QuoteResult
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		taxableTotal := decimal.Zero
		taxTotal := decimal.Zero

		for _, line := range lines {
			priced, err := priceLine(ctx, tx, line)
			if err != nil {
				return err
			}

			taxableTotal = taxableTotal.Add(priced.taxableValue)
			taxTotal = taxTotal.Add(priced.taxTotal)

			result.Lines = append(result.Lines, QuoteLine{
				ProductID: priced.product.ID, ProductName: priced.product.Name, Quantity: line.Quantity,
				UnitPrice: priced.unitPrice, TaxableValue: priced.taxableValue, TaxTotal: priced.taxTotal,
				LineTotal: priced.lineTotal,
			})
		}

		result.TaxableTotal = taxableTotal
		result.TaxTotal = taxTotal
		result.GrandTotal = taxableTotal.Add(taxTotal)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}
