package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/domain/accounting"
	"github.com/andipatti/feedmate/services/api/internal/domain/returns"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type ReturnsHandlers struct {
	Returns *returns.Service
}

type returnLineRequest struct {
	OriginalLineID    string  `json:"original_line_id"`
	Quantity          string  `json:"quantity"`
	ConditionStatus   string  `json:"condition_status,omitempty"`
	RestockLocationID *string `json:"restock_location_id,omitempty"`
}

type postReturnRequest struct {
	OriginalInvoiceID string              `json:"original_invoice_id"`
	Reason            string              `json:"reason,omitempty"`
	Lines             []returnLineRequest `json:"lines"`
	RefundMethod      string              `json:"refund_method"`
}

func (h *ReturnsHandlers) PostReturn(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}

	var req postReturnRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if len(req.Lines) == 0 {
		WriteError(w, reqID, CodeValidation, "at least one line is required")
		return
	}

	invoiceID, err := uuid.Parse(req.OriginalInvoiceID)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "original_invoice_id must be a valid UUID")
		return
	}

	svcReq := returns.PostReturnRequest{OriginalInvoiceID: invoiceID, Reason: req.Reason, RefundMethod: req.RefundMethod}

	for _, l := range req.Lines {
		lineID, err := uuid.Parse(l.OriginalLineID)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "line original_line_id must be a valid UUID")
			return
		}
		qty, err := decimal.NewFromString(l.Quantity)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "line quantity must be a valid decimal")
			return
		}
		line := returns.ReturnLineInput{OriginalLineID: lineID, Quantity: qty, ConditionStatus: l.ConditionStatus}
		if l.RestockLocationID != nil {
			locID, err := uuid.Parse(*l.RestockLocationID)
			if err != nil {
				WriteError(w, reqID, CodeValidation, "restock_location_id must be a valid UUID")
				return
			}
			line.RestockLocationID = &locID
		}
		svcReq.Lines = append(svcReq.Lines, line)
	}

	result, err := h.Returns.PostReturn(r.Context(), claims.TenantID, claims.DeviceID, claims.UserID, svcReq)
	if err != nil {
		switch {
		case errors.Is(err, returns.ErrValidation), errors.Is(err, returns.ErrExceedsSoldQuantity), errors.Is(err, returns.ErrOriginalInvoiceState):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, accounting.ErrNoActiveFinancialYear):
			WriteError(w, reqID, CodeConflict, "no active financial year is configured for this shop")
		default:
			WriteError(w, reqID, CodeInternal, "failed to post return: "+err.Error())
		}
		return
	}

	WriteJSON(w, http.StatusCreated, map[string]string{
		"return_id":     result.ReturnID.String(),
		"return_number": result.ReturnNumber,
		"total_refund":  result.TotalRefund.StringFixed(2),
	})
}
