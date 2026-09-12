package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/domain/customer"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type CustomerHandlers struct {
	Customer *customer.Service
}

type createCustomerRequest struct {
	CustomerCode  string `json:"customer_code"`
	Name          string `json:"name"`
	LocalName     string `json:"local_name,omitempty"`
	Phone         string `json:"phone,omitempty"`
	WhatsAppPhone string `json:"whatsapp_phone,omitempty"`
	CustomerType  string `json:"customer_type,omitempty"`
	CreditLimit   string `json:"credit_limit,omitempty"`
}

func customerToJSON(c *customer.Customer) map[string]interface{} {
	out := map[string]interface{}{
		"id":            c.ID.String(),
		"customer_code": c.CustomerCode,
		"name":          c.Name,
		"customer_type": c.CustomerType,
		"status":        c.Status,
	}
	if c.LocalName != nil {
		out["local_name"] = *c.LocalName
	}
	if c.Phone != nil {
		out["phone"] = *c.Phone
	}
	if c.WhatsAppPhone != nil {
		out["whatsapp_phone"] = *c.WhatsAppPhone
	}
	return out
}

func (h *CustomerHandlers) Create(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	var req createCustomerRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}

	in := customer.CreateInput{
		CustomerCode: req.CustomerCode, Name: req.Name, LocalName: req.LocalName,
		Phone: req.Phone, WhatsAppPhone: req.WhatsAppPhone, CustomerType: req.CustomerType,
	}
	if req.CreditLimit != "" {
		limit, err := decimal.NewFromString(req.CreditLimit)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "credit_limit must be a valid decimal")
			return
		}
		in.CreditLimit = &limit
	}

	created, err := h.Customer.Create(r.Context(), claims.TenantID, in)
	if err != nil {
		if errors.Is(err, customer.ErrValidation) {
			WriteError(w, reqID, CodeValidation, err.Error())
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to create customer: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusCreated, customerToJSON(created))
}

func (h *CustomerHandlers) List(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	query := r.URL.Query().Get("q")
	customers, err := h.Customer.List(r.Context(), claims.TenantID, query, 50)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list customers")
		return
	}
	out := make([]map[string]interface{}, 0, len(customers))
	for _, c := range customers {
		out = append(out, customerToJSON(&c))
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"customers": out})
}

func (h *CustomerHandlers) Get(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid customer id")
		return
	}
	c, profile, balance, err := h.Customer.GetByID(r.Context(), claims.TenantID, id)
	if err != nil {
		if errors.Is(err, customer.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "customer not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to fetch customer")
		return
	}
	resp := customerToJSON(c)
	resp["credit_limit"] = profile.CreditLimit.StringFixed(2)
	resp["risk_status"] = profile.RiskStatus
	resp["outstanding_balance"] = balance.StringFixed(2)
	resp["available_credit"] = profile.CreditLimit.Sub(balance).StringFixed(2)
	WriteJSON(w, http.StatusOK, resp)
}

type setCreditLimitRequest struct {
	CreditLimit string `json:"credit_limit"`
}

func (h *CustomerHandlers) SetCreditLimit(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid customer id")
		return
	}
	var req setCreditLimitRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	limit, err := decimal.NewFromString(req.CreditLimit)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "credit_limit must be a valid decimal")
		return
	}

	if err := h.Customer.SetCreditLimit(r.Context(), claims.TenantID, id, claims.UserID, limit); err != nil {
		switch {
		case errors.Is(err, customer.ErrValidation):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, customer.ErrNotFound):
			WriteError(w, reqID, CodeNotFound, "customer not found")
		default:
			WriteError(w, reqID, CodeInternal, "failed to update credit limit")
		}
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
