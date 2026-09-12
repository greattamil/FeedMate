package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/domain/payment"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type PaymentHandlers struct {
	Payment *payment.Service
}

type createReceiptIntentRequest struct {
	CustomerID     string `json:"customer_id"`
	Amount         string `json:"amount"`
	IdempotencyKey string `json:"idempotency_key"`
}

func (h *PaymentHandlers) CreateReceiptIntent(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}

	var req createReceiptIntentRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	customerID, err := uuid.Parse(req.CustomerID)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "customer_id must be a valid UUID")
		return
	}
	amount, err := decimal.NewFromString(req.Amount)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "amount must be a valid decimal")
		return
	}

	result, err := h.Payment.CreateReceiptIntent(r.Context(), claims.TenantID, payment.CreateReceiptIntentRequest{
		CustomerID: customerID, Amount: amount, IdempotencyKey: req.IdempotencyKey,
	})
	if err != nil {
		if errors.Is(err, payment.ErrValidation) {
			WriteError(w, reqID, CodeValidation, err.Error())
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to create payment intent")
		return
	}

	WriteJSON(w, http.StatusCreated, map[string]string{
		"intent_id":  result.IntentID.String(),
		"qr_payload": result.QRPayload,
		"status":     result.Status,
	})
}

func (h *PaymentHandlers) GetIntentStatus(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	intentID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid intent id")
		return
	}
	status, err := h.Payment.GetIntentStatus(r.Context(), claims.TenantID, intentID)
	if err != nil {
		if errors.Is(err, payment.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "payment intent not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to fetch payment status")
		return
	}
	WriteJSON(w, http.StatusOK, map[string]string{"status": status})
}

// SandboxWebhook receives asynchronous payment confirmations from the
// sandbox provider. This endpoint deliberately sits OUTSIDE the bearer-auth
// middleware group — an external payment gateway cannot present one of our
// user access tokens — and instead authenticates the caller purely via the
// provider's cryptographic webhook signature (PRD 11.1). It must never be
// placed behind RequireAuth.
func (h *PaymentHandlers) SandboxWebhook(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "failed to read request body")
		return
	}
	signature := r.Header.Get("X-Sandbox-Signature")

	if err := h.Payment.ProcessWebhook(r.Context(), body, signature); err != nil {
		switch {
		case errors.Is(err, payment.ErrInvalidSignature):
			WriteError(w, reqID, CodeUnauthorized, "invalid webhook signature")
		case errors.Is(err, payment.ErrIntentNotFound):
			WriteError(w, reqID, CodeValidation, "no matching payment intent for this order reference")
		case errors.Is(err, payment.ErrAmountMismatch):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, payment.ErrValidation):
			WriteError(w, reqID, CodeValidation, err.Error())
		default:
			WriteError(w, reqID, CodeInternal, "failed to process webhook")
		}
		return
	}
	WriteJSON(w, http.StatusOK, map[string]bool{"received": true})
}
