package pos

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

var ErrNoTaxProfile = errors.New("product has no active tax profile")

// TaxProfile is a point-in-time snapshot of tax_profiles, taken at invoice
// finalization time and stored on the invoice line so later master-data
// changes never rewrite historical invoices (PRD 9.4/23).
type TaxProfile struct {
	ID          uuid.UUID
	Code        string
	SupplyType  string
	CGSTRate    decimal.Decimal
	SGSTRate    decimal.Decimal
	IGSTRate    decimal.Decimal
	CessRate    decimal.Decimal
	PriceInclusive bool
}

func GetActiveTaxProfile(ctx context.Context, tx pgx.Tx, taxProfileID uuid.UUID) (*TaxProfile, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, code, supply_type, cgst_rate, sgst_rate, igst_rate, cess_rate, price_inclusive
		FROM tax_profiles
		WHERE id = $1 AND active
		  AND effective_from <= CURRENT_DATE
		  AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)
	`, taxProfileID)
	var tp TaxProfile
	err := row.Scan(&tp.ID, &tp.Code, &tp.SupplyType, &tp.CGSTRate, &tp.SGSTRate, &tp.IGSTRate, &tp.CessRate, &tp.PriceInclusive)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNoTaxProfile
		}
		return nil, err
	}
	return &tp, nil
}

type TaxComponent struct {
	Type   string // CGST, SGST, IGST, CESS
	Rate   decimal.Decimal
	Amount decimal.Decimal
}

// CalculateLineTax computes each applicable tax component on the given
// taxable value, rounded to 2 decimal places (rounding must be deterministic
// per PRD 9.4). Zero-rate components are omitted from the result but still
// contribute correctly (as zero) to the total.
func CalculateLineTax(tp *TaxProfile, taxableValue decimal.Decimal) (components []TaxComponent, total decimal.Decimal) {
	add := func(taxType string, rate decimal.Decimal) {
		if rate.IsZero() {
			return
		}
		amount := taxableValue.Mul(rate).Div(decimal.NewFromInt(100)).Round(2)
		components = append(components, TaxComponent{Type: taxType, Rate: rate, Amount: amount})
		total = total.Add(amount)
	}
	add("CGST", tp.CGSTRate)
	add("SGST", tp.SGSTRate)
	add("IGST", tp.IGSTRate)
	add("CESS", tp.CessRate)
	return components, total
}
