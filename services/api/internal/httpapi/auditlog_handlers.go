package httpapi

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"

	"github.com/andipatti/feedmate/services/api/internal/domain/auditlog"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type AuditLogHandlers struct {
	AuditLog *auditlog.Service
}

// List returns audit log entries newest-first, optionally filtered by a
// substring match on action code/entity type (`q`) or an exact entity id
// (`entity_id`), paginated via `limit`/`offset`. Read-only: there is no
// write endpoint for this resource anywhere in the API, by design.
func (h *AuditLogHandlers) List(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	query := r.URL.Query().Get("q")
	var entityID *uuid.UUID
	if v := r.URL.Query().Get("entity_id"); v != "" {
		id, err := uuid.Parse(v)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "entity_id must be a valid UUID")
			return
		}
		entityID = &id
	}
	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			limit = n
		}
	}
	offset := 0
	if v := r.URL.Query().Get("offset"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			offset = n
		}
	}

	page, err := h.AuditLog.List(r.Context(), claims.TenantID, query, entityID, limit, offset)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list audit log: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(page.Entries))
	for _, e := range page.Entries {
		row := map[string]interface{}{
			"id":          e.ID.String(),
			"action_code": e.ActionCode,
			"entity_type": e.EntityType,
			"created_at":  e.CreatedAt.Format(time.RFC3339),
		}
		if e.ActorUserID != nil {
			row["actor_user_id"] = e.ActorUserID.String()
		}
		if e.ActorName != nil {
			row["actor_name"] = *e.ActorName
		}
		if e.EntityID != nil {
			row["entity_id"] = e.EntityID.String()
		}
		if e.Reason != nil {
			row["reason"] = *e.Reason
		}
		if len(e.BeforeJSON) > 0 {
			var before interface{}
			if json.Unmarshal(e.BeforeJSON, &before) == nil {
				row["before"] = before
			}
		}
		if len(e.AfterJSON) > 0 {
			var after interface{}
			if json.Unmarshal(e.AfterJSON, &after) == nil {
				row["after"] = after
			}
		}
		out = append(out, row)
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"entries": out, "total": page.Total})
}
