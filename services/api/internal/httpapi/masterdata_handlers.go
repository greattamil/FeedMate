package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/andipatti/feedmate/services/api/internal/domain/masterdata"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

// MasterDataHandlers exposes the small lookup lists a product create/edit
// form needs (categories, brands, UOMs, tax profiles). Categories and
// brands also get a create/deactivate path (see masterdata.go's package
// doc comment on why UOMs and tax profiles stay list-only).
type MasterDataHandlers struct {
	MasterData *masterdata.Service
}

func (h *MasterDataHandlers) ListCategories(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	categories, err := h.MasterData.ListCategories(r.Context(), claims.TenantID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list categories: "+err.Error())
		return
	}
	out := make([]map[string]string, 0, len(categories))
	for _, c := range categories {
		out = append(out, map[string]string{"id": c.ID.String(), "name": c.Name})
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"categories": out})
}

type createCategoryRequest struct {
	Name      string `json:"name"`
	LocalName string `json:"local_name,omitempty"`
}

func (h *MasterDataHandlers) CreateCategory(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	var req createCategoryRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	created, err := h.MasterData.CreateCategory(r.Context(), claims.TenantID, req.Name, req.LocalName)
	if err != nil {
		if errors.Is(err, masterdata.ErrValidation) {
			WriteError(w, reqID, CodeValidation, err.Error())
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to create category: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusCreated, map[string]string{"id": created.ID.String(), "name": created.Name})
}

type setActiveRequest struct {
	Active bool `json:"active"`
}

func (h *MasterDataHandlers) SetCategoryActive(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid category id")
		return
	}
	var req setActiveRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if err := h.MasterData.SetCategoryActive(r.Context(), claims.TenantID, id, req.Active); err != nil {
		if errors.Is(err, masterdata.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "category not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to update category status: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *MasterDataHandlers) ListBrands(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	brands, err := h.MasterData.ListBrands(r.Context(), claims.TenantID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list brands: "+err.Error())
		return
	}
	out := make([]map[string]string, 0, len(brands))
	for _, b := range brands {
		out = append(out, map[string]string{"id": b.ID.String(), "name": b.Name})
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"brands": out})
}

type createBrandRequest struct {
	Name      string `json:"name"`
	LocalName string `json:"local_name,omitempty"`
}

func (h *MasterDataHandlers) CreateBrand(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	var req createBrandRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	created, err := h.MasterData.CreateBrand(r.Context(), claims.TenantID, req.Name, req.LocalName)
	if err != nil {
		if errors.Is(err, masterdata.ErrValidation) {
			WriteError(w, reqID, CodeValidation, err.Error())
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to create brand: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusCreated, map[string]string{"id": created.ID.String(), "name": created.Name})
}

func (h *MasterDataHandlers) SetBrandActive(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid brand id")
		return
	}
	var req setActiveRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if err := h.MasterData.SetBrandActive(r.Context(), claims.TenantID, id, req.Active); err != nil {
		if errors.Is(err, masterdata.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "brand not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to update brand status: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *MasterDataHandlers) ListUOMs(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	uoms, err := h.MasterData.ListUOMs(r.Context(), claims.TenantID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list UOMs: "+err.Error())
		return
	}
	out := make([]map[string]string, 0, len(uoms))
	for _, u := range uoms {
		out = append(out, map[string]string{"id": u.ID.String(), "code": u.Code, "name": u.Name})
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"uoms": out})
}

func (h *MasterDataHandlers) ListTaxProfiles(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	profiles, err := h.MasterData.ListTaxProfiles(r.Context(), claims.TenantID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list tax profiles: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(profiles))
	for _, t := range profiles {
		out = append(out, map[string]interface{}{
			"id":          t.ID.String(),
			"code":        t.Code,
			"description": t.Description,
			"cgst_rate":   t.CGSTRate.String(),
			"sgst_rate":   t.SGSTRate.String(),
			"igst_rate":   t.IGSTRate.String(),
		})
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"tax_profiles": out})
}
