package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/andipatti/feedmate/services/api/internal/domain/supplier"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type SupplierHandlers struct {
	Supplier *supplier.Service
}

type createSupplierRequest struct {
	Name             string `json:"name"`
	TradeName        string `json:"trade_name,omitempty"`
	GSTIN            string `json:"gstin,omitempty"`
	Phone            string `json:"phone,omitempty"`
	Email            string `json:"email,omitempty"`
	PaymentTermsDays int    `json:"payment_terms_days,omitempty"`
}

func supplierToJSON(s *supplier.Supplier) map[string]interface{} {
	out := map[string]interface{}{
		"id":                 s.ID.String(),
		"supplier_code":      s.SupplierCode,
		"name":               s.Name,
		"payment_terms_days": s.PaymentTermsDays,
		"status":             s.Status,
	}
	if s.TradeName != nil {
		out["trade_name"] = *s.TradeName
	}
	if s.GSTIN != nil {
		out["gstin"] = *s.GSTIN
	}
	if s.Phone != nil {
		out["phone"] = *s.Phone
	}
	if s.Email != nil {
		out["email"] = *s.Email
	}
	return out
}

func (h *SupplierHandlers) Create(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	var req createSupplierRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}

	created, err := h.Supplier.Create(r.Context(), claims.TenantID, supplier.CreateInput{
		Name: req.Name, TradeName: req.TradeName,
		GSTIN: req.GSTIN, Phone: req.Phone, Email: req.Email, PaymentTermsDays: req.PaymentTermsDays,
	})
	if err != nil {
		if errors.Is(err, supplier.ErrValidation) {
			WriteError(w, reqID, CodeValidation, err.Error())
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to create supplier: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusCreated, supplierToJSON(created))
}

type updateSupplierRequest struct {
	Name             string `json:"name"`
	TradeName        string `json:"trade_name,omitempty"`
	GSTIN            string `json:"gstin,omitempty"`
	Phone            string `json:"phone,omitempty"`
	Email            string `json:"email,omitempty"`
	PaymentTermsDays int    `json:"payment_terms_days,omitempty"`
}

// Update revises a supplier's editable fields. supplier_code is immutable
// and not accepted here — see supplier.Update's doc comment.
func (h *SupplierHandlers) Update(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid supplier id")
		return
	}
	var req updateSupplierRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}

	updated, err := h.Supplier.Update(r.Context(), claims.TenantID, id, supplier.UpdateInput{
		Name: req.Name, TradeName: req.TradeName, GSTIN: req.GSTIN,
		Phone: req.Phone, Email: req.Email, PaymentTermsDays: req.PaymentTermsDays,
	})
	if err != nil {
		if errors.Is(err, supplier.ErrValidation) {
			WriteError(w, reqID, CodeValidation, err.Error())
			return
		}
		if errors.Is(err, supplier.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "supplier not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to update supplier: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, supplierToJSON(updated))
}

type setSupplierStatusRequest struct {
	Active bool `json:"active"`
}

// SetStatus activates or deactivates a supplier — never a hard delete, since
// historical GRN/payment rows reference it (mirrors ProductHandlers.SetStatus).
func (h *SupplierHandlers) SetStatus(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid supplier id")
		return
	}
	var req setSupplierStatusRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	updated, err := h.Supplier.SetActive(r.Context(), claims.TenantID, id, req.Active)
	if err != nil {
		if errors.Is(err, supplier.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "supplier not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to update supplier status: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, supplierToJSON(updated))
}

func (h *SupplierHandlers) List(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	query := r.URL.Query().Get("q")
	suppliers, err := h.Supplier.List(r.Context(), claims.TenantID, query, 50)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list suppliers: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(suppliers))
	for _, s := range suppliers {
		m := supplierToJSON(&s)
		m["payable"] = s.Payable.StringFixed(2)
		out = append(out, m)
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"suppliers": out})
}

func (h *SupplierHandlers) Get(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid supplier id")
		return
	}
	s, balance, err := h.Supplier.GetByID(r.Context(), claims.TenantID, id)
	if err != nil {
		if errors.Is(err, supplier.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "supplier not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to fetch supplier: "+err.Error())
		return
	}
	resp := supplierToJSON(s)
	resp["outstanding_payable"] = balance.StringFixed(2)
	WriteJSON(w, http.StatusOK, resp)
}

func (h *SupplierHandlers) Ledger(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid supplier id")
		return
	}
	limit := 100
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			limit = n
		}
	}
	entries, err := h.Supplier.ListLedger(r.Context(), claims.TenantID, id, limit)
	if err != nil {
		if errors.Is(err, supplier.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "supplier not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to fetch ledger: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(entries))
	for _, e := range entries {
		row := map[string]interface{}{
			"id":            e.ID.String(),
			"entry_date":    e.EntryDate.Format(time.RFC3339),
			"document_type": e.DocumentType,
			"document_id":   e.DocumentID.String(),
			"debit":         e.Debit.StringFixed(2),
			"credit":        e.Credit.StringFixed(2),
		}
		if e.Description != nil {
			row["description"] = *e.Description
		}
		out = append(out, row)
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"entries": out})
}
