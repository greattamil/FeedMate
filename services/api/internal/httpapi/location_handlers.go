package httpapi

import (
	"net/http"

	"github.com/andipatti/feedmate/services/api/internal/domain/location"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type LocationHandlers struct {
	Location *location.Service
}

func (h *LocationHandlers) List(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	locations, err := h.Location.ListActive(r.Context(), claims.TenantID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to fetch locations")
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
