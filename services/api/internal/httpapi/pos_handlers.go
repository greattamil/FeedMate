package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/domain/accounting"
	"github.com/andipatti/feedmate/services/api/internal/domain/inventory"
	"github.com/andipatti/feedmate/services/api/internal/domain/pos"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type POSHandlers struct {
	POS *pos.Service
}

type finalizeLineRequest struct {
	ProductID         string  `json:"product_id"`
	Quantity          string  `json:"quantity"`
	UnitPriceOverride *string `json:"unit_price_override,omitempty"`
	DiscountAmount    string  `json:"discount_amount,omitempty"`
}

type finalizeTenderRequest struct {
	Method string `json:"method"`
	Amount string `json:"amount"`
}

type finalizeRequest struct {
	ClientTransactionID  string                  `json:"client_transaction_id"`
	LocationID           string                  `json:"location_id"`
	CustomerID           string                  `json:"customer_id,omitempty"`
	Lines                []finalizeLineRequest   `json:"lines"`
	Tenders              []finalizeTenderRequest `json:"tenders"`
	OverrideCreditLimit  bool                    `json:"override_credit_limit,omitempty"`
	OverrideReason       string                  `json:"override_reason,omitempty"`
}

type finalizeResponse struct {
	InvoiceID     string `json:"invoice_id"`
	InvoiceNumber string `json:"invoice_number"`
	GrandTotal    string `json:"grand_total"`
	Duplicate     bool   `json:"duplicate"`
}

func (h *POSHandlers) FinalizeInvoice(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}

	var req finalizeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}

	clientTxID, err := uuid.Parse(req.ClientTransactionID)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "client_transaction_id must be a valid UUID")
		return
	}
	locationID, err := uuid.Parse(req.LocationID)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "location_id must be a valid UUID")
		return
	}
	if len(req.Lines) == 0 {
		WriteError(w, reqID, CodeValidation, "at least one line is required")
		return
	}

	svcReq := pos.FinalizeRequest{
		ClientTransactionID: clientTxID,
		LocationID:          locationID,
	}

	if req.CustomerID != "" {
		customerID, err := uuid.Parse(req.CustomerID)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "customer_id must be a valid UUID")
			return
		}
		svcReq.CustomerID = &customerID
	}

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
		svcReq.Lines = append(svcReq.Lines, line)
	}

	for _, t := range req.Tenders {
		amount, err := decimal.NewFromString(t.Amount)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "tender amount must be a valid decimal")
			return
		}
		svcReq.Tenders = append(svcReq.Tenders, pos.Tender{Method: t.Method, Amount: amount})
	}

	// A credit-limit override must be an explicit, per-sale operator decision
	// with a reason (PRD 10.1) — never an automatic bypass just because the
	// logged-in role happens to include the credit.override permission.
	if req.OverrideCreditLimit {
		hasPermission := false
		for _, p := range claims.Permissions {
			if p == "credit.override" {
				hasPermission = true
				break
			}
		}
		if !hasPermission {
			WriteError(w, reqID, CodeForbidden, "missing required permission: credit.override")
			return
		}
		if req.OverrideReason == "" {
			WriteError(w, reqID, CodeValidation, "override_reason is required when override_credit_limit is true")
			return
		}
		svcReq.CreditOverride.Requested = true
		svcReq.CreditOverride.Reason = req.OverrideReason
	}

	result, err := h.POS.FinalizeInvoice(r.Context(), claims.TenantID, claims.DeviceID, claims.UserID, svcReq)
	if err != nil {
		switch {
		case errors.Is(err, pos.ErrValidation), errors.Is(err, pos.ErrTenderMismatch), errors.Is(err, pos.ErrNoTaxProfile):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, inventory.ErrInsufficientStock):
			WriteError(w, reqID, CodeInsufficientStock, err.Error())
		case errors.Is(err, pos.ErrCreditLimitExceeded):
			WriteError(w, reqID, CodeCreditLimitExceeded, err.Error())
		case errors.Is(err, accounting.ErrNoActiveFinancialYear):
			WriteError(w, reqID, CodeConflict, "no active financial year is configured for this shop")
		default:
			WriteError(w, reqID, CodeInternal, "failed to finalize invoice: "+err.Error())
		}
		return
	}

	status := http.StatusCreated
	if result.Duplicate {
		status = http.StatusOK
	}
	WriteJSON(w, status, finalizeResponse{
		InvoiceID:     result.InvoiceID.String(),
		InvoiceNumber: result.InvoiceNumber,
		GrandTotal:    result.GrandTotal.StringFixed(2),
		Duplicate:     result.Duplicate,
	})
}
