package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/domain/accounting"
	"github.com/andipatti/feedmate/services/api/internal/domain/contra"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type ContraHandlers struct {
	Contra *contra.Service
}

type contraLineRequest struct {
	ProductID          string  `json:"product_id"`
	BatchCode          string  `json:"batch_code"`
	ManufactureDate    *string `json:"manufacture_date,omitempty"`
	ExpiryDate         *string `json:"expiry_date,omitempty"`
	Quantity           string  `json:"quantity"`
	UOMID              string  `json:"uom_id"`
	ValuationUnitPrice string  `json:"valuation_unit_price"`
	QualityStatus      string  `json:"quality_status,omitempty"`
	LocationID         string  `json:"location_id"`
}

type postContraRequest struct {
	CustomerID      string              `json:"customer_id"`
	SourceReference string              `json:"source_reference,omitempty"`
	Lines           []contraLineRequest `json:"lines"`
}

func (h *ContraHandlers) PostContra(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}

	var req postContraRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if len(req.Lines) == 0 {
		WriteError(w, reqID, CodeValidation, "at least one line is required")
		return
	}
	customerID, err := uuid.Parse(req.CustomerID)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "customer_id must be a valid UUID")
		return
	}

	svcReq := contra.PostContraRequest{CustomerID: customerID, SourceReference: req.SourceReference}
	for _, l := range req.Lines {
		productID, err := uuid.Parse(l.ProductID)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "line product_id must be a valid UUID")
			return
		}
		uomID, err := uuid.Parse(l.UOMID)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "line uom_id must be a valid UUID")
			return
		}
		locationID, err := uuid.Parse(l.LocationID)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "line location_id must be a valid UUID")
			return
		}
		qty, err := decimal.NewFromString(l.Quantity)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "quantity must be a valid decimal")
			return
		}
		price, err := decimal.NewFromString(l.ValuationUnitPrice)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "valuation_unit_price must be a valid decimal")
			return
		}
		line := contra.ContraLineInput{
			ProductID: productID, BatchCode: l.BatchCode, Quantity: qty, UOMID: uomID,
			ValuationUnitPrice: price, QualityStatus: l.QualityStatus, LocationID: locationID,
		}
		if l.ManufactureDate != nil && *l.ManufactureDate != "" {
			t, err := time.Parse("2006-01-02", *l.ManufactureDate)
			if err != nil {
				WriteError(w, reqID, CodeValidation, "manufacture_date must be YYYY-MM-DD")
				return
			}
			line.ManufactureDate = &t
		}
		if l.ExpiryDate != nil && *l.ExpiryDate != "" {
			t, err := time.Parse("2006-01-02", *l.ExpiryDate)
			if err != nil {
				WriteError(w, reqID, CodeValidation, "expiry_date must be YYYY-MM-DD")
				return
			}
			line.ExpiryDate = &t
		}
		svcReq.Lines = append(svcReq.Lines, line)
	}

	result, err := h.Contra.PostContra(r.Context(), claims.TenantID, claims.DeviceID, claims.UserID, svcReq)
	if err != nil {
		switch {
		case errors.Is(err, contra.ErrValidation):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, accounting.ErrNoActiveFinancialYear):
			WriteError(w, reqID, CodeConflict, "no active financial year is configured for this shop")
		default:
			WriteError(w, reqID, CodeInternal, "failed to post contra transaction: "+err.Error())
		}
		return
	}

	WriteJSON(w, http.StatusCreated, map[string]string{
		"contra_id":     result.ContraID.String(),
		"contra_number": result.ContraNumber,
		"total_value":   result.TotalValue.StringFixed(2),
	})
}
