package httpapi

import (
	"context"
	"net/http"
	"time"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
)

type HealthHandlers struct {
	DB *dbctx.DB
}

// Live reports process liveness only — no dependency checks. Used by the
// container orchestrator to decide whether to restart the process.
func (h *HealthHandlers) Live(w http.ResponseWriter, r *http.Request) {
	WriteJSON(w, http.StatusOK, map[string]string{"status": "live"})
}

// Ready reports whether required dependencies (PostgreSQL) are reachable. Used
// by the orchestrator/load balancer to decide whether to route traffic here.
func (h *HealthHandlers) Ready(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	if err := h.DB.Pool.Ping(ctx); err != nil {
		WriteJSON(w, http.StatusServiceUnavailable, map[string]string{
			"status": "not_ready",
			"reason": "database unreachable",
		})
		return
	}
	WriteJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}
