package httpapi

import (
	"net/http"

	"github.com/andipatti/feedmate/services/api/internal/domain/masterdata"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

// MasterDataHandlers exposes the small read-only lookup lists a product
// create/edit form needs (categories, brands, UOMs, tax profiles). There is
// no write path here — these are managed by seed/setup workflows, not this
// API, at least until an admin/setup UI exists for them (see
// docs/IMPLEMENTATION_STATUS.md's "Not Yet Started" list).
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
