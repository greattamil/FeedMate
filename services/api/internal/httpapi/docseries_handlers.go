package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/andipatti/feedmate/services/api/internal/domain/docseries"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

// DocSeriesHandlers exposes admin control over financial years and their
// document-numbering series — see docseries.go's package doc comment on
// why this exists (a missing series row previously surfaced only as an
// opaque INTERNAL_ERROR at the moment a cashier tried to finalize a sale).
type DocSeriesHandlers struct {
	DocSeries *docseries.Service
}

func financialYearToJSON(f docseries.FinancialYear) map[string]interface{} {
	out := map[string]interface{}{
		"id":         f.ID.String(),
		"label":      f.Label,
		"start_date": f.StartDate.Format("2006-01-02"),
		"end_date":   f.EndDate.Format("2006-01-02"),
		"status":     f.Status,
	}
	if f.ClosedAt != nil {
		out["closed_at"] = f.ClosedAt.Format(time.RFC3339)
	}
	return out
}

func (h *DocSeriesHandlers) ListFinancialYears(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	years, err := h.DocSeries.ListFinancialYears(r.Context(), claims.TenantID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list financial years: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(years))
	for _, y := range years {
		out = append(out, financialYearToJSON(y))
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"financial_years": out})
}

type createFinancialYearRequest struct {
	Label     string `json:"label"`
	StartDate string `json:"start_date"`
	EndDate   string `json:"end_date"`
}

func (h *DocSeriesHandlers) CreateFinancialYear(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	var req createFinancialYearRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	startDate, err := time.Parse("2006-01-02", req.StartDate)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "start_date must be YYYY-MM-DD")
		return
	}
	endDate, err := time.Parse("2006-01-02", req.EndDate)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "end_date must be YYYY-MM-DD")
		return
	}
	id, err := h.DocSeries.CreateFinancialYear(r.Context(), claims.TenantID, claims.UserID, req.Label, startDate, endDate)
	if err != nil {
		if errors.Is(err, docseries.ErrValidation) {
			WriteError(w, reqID, CodeValidation, err.Error())
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to create financial year: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusCreated, map[string]string{"id": id.String()})
}

func (h *DocSeriesHandlers) CloseFinancialYear(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid financial year id")
		return
	}
	if err := h.DocSeries.CloseFinancialYear(r.Context(), claims.TenantID, claims.UserID, id); err != nil {
		if errors.Is(err, docseries.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "financial year not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to close financial year: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func documentSeriesToJSON(d docseries.DocumentSeries) map[string]interface{} {
	return map[string]interface{}{
		"id":                d.ID.String(),
		"financial_year_id": d.FinancialYearID.String(),
		"document_type":     d.DocumentType,
		"prefix":            d.Prefix,
		"next_number":       d.NextNumber,
		"padding":           d.Padding,
		"active":            d.Active,
	}
}

func (h *DocSeriesHandlers) ListDocumentSeries(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	financialYearID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid financial year id")
		return
	}
	series, err := h.DocSeries.ListDocumentSeries(r.Context(), claims.TenantID, financialYearID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list document series: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(series))
	for _, s := range series {
		out = append(out, documentSeriesToJSON(s))
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"document_series": out})
}

type createDocumentSeriesRequest struct {
	DocumentType   string `json:"document_type"`
	Prefix         string `json:"prefix"`
	StartingNumber int64  `json:"starting_number"`
	Padding        int    `json:"padding"`
}

func (h *DocSeriesHandlers) CreateDocumentSeries(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	financialYearID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid financial year id")
		return
	}
	var req createDocumentSeriesRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	id, err := h.DocSeries.CreateDocumentSeries(r.Context(), claims.TenantID, claims.UserID, financialYearID,
		req.DocumentType, req.Prefix, req.StartingNumber, req.Padding)
	if err != nil {
		if errors.Is(err, docseries.ErrValidation) {
			WriteError(w, reqID, CodeValidation, err.Error())
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to create document series: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusCreated, map[string]string{"id": id.String()})
}

type setSeriesActiveRequest struct {
	Active bool `json:"active"`
}

func (h *DocSeriesHandlers) SetDocumentSeriesActive(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid document series id")
		return
	}
	var req setSeriesActiveRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if err := h.DocSeries.SetDocumentSeriesActive(r.Context(), claims.TenantID, id, req.Active); err != nil {
		if errors.Is(err, docseries.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "document series not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to update document series status: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type seedDefaultSeriesRequest struct {
	LabelPrefix string `json:"label_prefix"`
}

// SeedDefaultSeries is the one-click fix: creates an active series for
// every core document type this app needs (INVOICE/GRN/RETURN/CONTRA/
// RECEIPT) that doesn't already have one in this financial year.
func (h *DocSeriesHandlers) SeedDefaultSeries(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	financialYearID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid financial year id")
		return
	}
	var req seedDefaultSeriesRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	created, err := h.DocSeries.SeedDefaultSeries(r.Context(), claims.TenantID, claims.UserID, financialYearID, req.LabelPrefix)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to seed default series: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(created))
	for _, s := range created {
		out = append(out, documentSeriesToJSON(s))
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"created": out})
}
