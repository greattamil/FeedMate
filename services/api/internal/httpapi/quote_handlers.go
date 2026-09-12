package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/domain/pos"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type quoteRequest struct {
	Lines []finalizeLineRequest `json:"lines"`
}

// Quote lets the POS UI show the cashier an accurate, server-computed total
// (unit price, discount, tax) before checkout, without duplicating the tax
// calculation client-side and without allocating stock or writing anything —
// see pos.Service.Quote / pos/quote.go for why this exists.
func (h *POSHandlers) Quote(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}

	var req quoteRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if len(req.Lines) == 0 {
		WriteError(w, reqID, CodeValidation, "at least one line is required")
		return
	}

	var lines []pos.SaleLine
	for _, l := range req.Lines {
		productID, err := uuid.Parse(l.ProductID)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "line product_id must be a valid UUID")
			return
		}
		qty, err := decimal.NewFromString(l.Quantity)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "line quantity must be a valid decimal")
			return
		}
		discount := decimal.Zero
		if l.DiscountAmount != "" {
			discount, err = decimal.NewFromString(l.DiscountAmount)
			if err != nil {
				WriteError(w, reqID, CodeValidation, "discount_amount must be a valid decimal")
				return
			}
		}
		line := pos.SaleLine{ProductID: productID, Quantity: qty, DiscountAmount: discount}
		if l.UnitPriceOverride != nil {
			price, err := decimal.NewFromString(*l.UnitPriceOverride)
			if err != nil {
				WriteError(w, reqID, CodeValidation, "unit_price_override must be a valid decimal")
				return
			}
			line.UnitPriceOverride = &price
		}
		lines = append(lines, line)
	}

	result, err := h.POS.Quote(r.Context(), claims.TenantID, lines)
	if err != nil {
		if errors.Is(err, pos.ErrValidation) || errors.Is(err, pos.ErrNoTaxProfile) {
			WriteError(w, reqID, CodeValidation, err.Error())
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to compute quote")
		return
	}

	lineOut := make([]map[string]string, 0, len(result.Lines))
	for _, l := range result.Lines {
		lineOut = append(lineOut, map[string]string{
			"product_id":    l.ProductID.String(),
			"product_name":  l.ProductName,
			"quantity":      l.Quantity.String(),
			"unit_price":    l.UnitPrice.StringFixed(2),
			"taxable_value": l.TaxableValue.StringFixed(2),
			"tax_total":     l.TaxTotal.StringFixed(2),
			"line_total":    l.LineTotal.StringFixed(2),
		})
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{
		"lines":         lineOut,
		"taxable_total": result.TaxableTotal.StringFixed(2),
		"tax_total":     result.TaxTotal.StringFixed(2),
		"grand_total":   result.GrandTotal.StringFixed(2),
	})
}
