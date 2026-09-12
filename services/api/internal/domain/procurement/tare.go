package procurement

import (
	"errors"
	"fmt"

	"github.com/shopspring/decimal"
)

var (
	ErrTareNegativeNet    = errors.New("computed net weight is negative or implausibly low")
	ErrTareExceedsThreshold = errors.New("tare weight exceeds the configured maximum threshold")
)

// TareCalculation is the result of PRD A7's mandatory GRN weight validation:
// gross, tare and net weight are calculated and shown separately, and the
// system must never assume a tare figure without an explicit, visible
// calculation.
type TareCalculation struct {
	GrossWeightKg decimal.Decimal
	TareWeightKg  decimal.Decimal
	NetWeightKg   decimal.Decimal
	MaxAllowedTareKg decimal.Decimal
	ExceedsThreshold bool
}

// CalculateTare computes tare either from an explicitly measured value or
// from bag count x standard tare per bag (PRD A7: "For count-based tare, the
// system must calculate tare from bag count x configured tare per bag and
// show both the formula and result"). It never silently assumes a tare
// value — the caller must supply one of the two methods explicitly.
func CalculateTare(method string, grossWeightKg decimal.Decimal, measuredTareKg *decimal.Decimal, bagCount *int, standardTarePerBagKg *decimal.Decimal, thresholdPct decimal.Decimal) (*TareCalculation, error) {
	var tareWeight decimal.Decimal
	switch method {
	case "MEASURED":
		if measuredTareKg == nil {
			return nil, fmt.Errorf("measured tare weight is required for tare_method=MEASURED")
		}
		tareWeight = *measuredTareKg
	case "COUNT_BASED":
		if bagCount == nil || standardTarePerBagKg == nil {
			return nil, fmt.Errorf("bag_count and standard_tare_per_bag_kg are required for tare_method=COUNT_BASED")
		}
		tareWeight = standardTarePerBagKg.Mul(decimal.NewFromInt(int64(*bagCount)))
	case "MANUAL":
		if measuredTareKg == nil {
			return nil, fmt.Errorf("tare weight is required for tare_method=MANUAL")
		}
		tareWeight = *measuredTareKg
	default:
		return nil, fmt.Errorf("unknown tare_method %q", method)
	}

	netWeight := grossWeightKg.Sub(tareWeight)
	if netWeight.LessThanOrEqual(decimal.Zero) {
		return nil, fmt.Errorf("%w: gross=%s tare=%s net=%s", ErrTareNegativeNet, grossWeightKg, tareWeight, netWeight)
	}

	maxAllowedTare := grossWeightKg.Mul(thresholdPct).Div(decimal.NewFromInt(100))
	calc := &TareCalculation{
		GrossWeightKg: grossWeightKg, TareWeightKg: tareWeight, NetWeightKg: netWeight,
		MaxAllowedTareKg: maxAllowedTare, ExceedsThreshold: tareWeight.GreaterThan(maxAllowedTare),
	}
	return calc, nil
}
