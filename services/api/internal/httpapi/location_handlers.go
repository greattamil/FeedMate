package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/andipatti/feedmate/services/api/internal/domain/location"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type LocationHandlers struct {
	Location *location.Service
}

func locationJSON(l location.Location) map[string]interface{} {
	return map[string]interface{}{
		"id": l.ID.String(), "code": l.Code, "name": l.Name, "type": l.Type, "active": l.Active,
	}
}

// List returns only active locations — what a GRN/stock-count/POS
// location picker should offer.
func (h *LocationHandlers) List(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	locations, err := h.Location.ListActive(r.Context(), claims.TenantID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to fetch locations: "+err.Error())
		return
	}
	out := make([]map[string]string, 0, len(locations))
	for _, l := range locations {
		out = append(out, map[string]string{
			"id": l.ID.String(), "code": l.Code, "name": l.Name, "type": l.Type,
		})
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"locations": out})
}

// ListAll includes inactive locations — the dedicated management screen,
// gated on product.manage like the rest of this app's master-data
// mutation endpoints.
func (h *LocationHandlers) ListAll(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	locations, err := h.Location.ListAll(r.Context(), claims.TenantID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to fetch locations: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(locations))
	for _, l := range locations {
		out = append(out, locationJSON(l))
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"locations": out})
}

type locationRequest struct {
	Code string `json:"code"`
	Name string `json:"name"`
	Type string `json:"type"`
}

func (h *LocationHandlers) Create(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	var req locationRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	created, err := h.Location.Create(r.Context(), claims.TenantID, req.Code, req.Name, req.Type)
	if err != nil {
		if errors.Is(err, location.ErrValidation) {
			WriteError(w, reqID, CodeValidation, err.Error())
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to create location: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusCreated, locationJSON(*created))
}

func (h *LocationHandlers) Update(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid location id")
		return
	}
	var req locationRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if err := h.Location.Update(r.Context(), claims.TenantID, id, req.Name, req.Type); err != nil {
		if errors.Is(err, location.ErrValidation) {
			WriteError(w, reqID, CodeValidation, err.Error())
			return
		}
		if errors.Is(err, location.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "location not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to update location: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *LocationHandlers) SetActive(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid location id")
		return
	}
	var req setActiveRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if err := h.Location.SetActive(r.Context(), claims.TenantID, id, req.Active); err != nil {
		if errors.Is(err, location.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "location not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to update location status: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
