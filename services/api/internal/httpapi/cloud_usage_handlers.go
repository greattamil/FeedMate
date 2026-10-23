package httpapi

import (
	"encoding/json"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/andipatti/feedmate/services/api/internal/domain/cloudusage"
)

// CloudUsageHandlers is the platform-admin live cloud usage dashboard —
// registered in the same RequirePlatform route group as PlatformHandlers
// (see cmd/api/main.go), since it's cross-tenant, super-admin-only data.
type CloudUsageHandlers struct {
	CloudUsage *cloudusage.Service
}

func usageJSON(u cloudusage.LatestUsage) map[string]interface{} {
	row := map[string]interface{}{
		"provider":      u.Provider,
		"metric_key":    u.MetricKey,
		"label":         u.Label,
		"used_value":    u.UsedValue,
		"unit":          u.Unit,
		"limit_is_live": u.LimitIsLive,
		"captured_at":   u.CapturedAt,
	}
	if u.LimitValue != nil {
		row["limit_value"] = *u.LimitValue
	}
	if u.PctUsed != nil {
		row["pct_used"] = *u.PctUsed
	}
	return row
}

func alertJSON(a cloudusage.Alert) map[string]interface{} {
	row := map[string]interface{}{
		"id":         a.ID,
		"provider":   a.Provider,
		"metric_key": a.MetricKey,
		"severity":   a.Severity,
		"message":    a.Message,
		"pct_used":   a.PctUsed,
		"created_at": a.CreatedAt,
	}
	if a.ResolvedAt != nil {
		row["resolved_at"] = *a.ResolvedAt
	}
	return row
}

func (h *CloudUsageHandlers) ListUsage(w http.ResponseWriter, r *http.Request) {
	usage, err := h.CloudUsage.ListLatestUsage(r.Context())
	if err != nil {
		WriteError(w, r, CodeInternal, "failed to list cloud usage: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(usage))
	for _, u := range usage {
		out = append(out, usageJSON(u))
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"metrics": out})
}

func (h *CloudUsageHandlers) ListAlerts(w http.ResponseWriter, r *http.Request) {
	alerts, err := h.CloudUsage.ListActiveAlerts(r.Context())
	if err != nil {
		WriteError(w, r, CodeInternal, "failed to list cloud usage alerts: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(alerts))
	for _, a := range alerts {
		out = append(out, alertJSON(a))
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"alerts": out})
}

// Refresh triggers an immediate poll of every provider (for a "Refresh
// now" button) instead of waiting for the hourly scheduler — it runs the
// exact same RunPollOnce the scheduler uses, so there is only one code
// path that ever talks to the providers.
func (h *CloudUsageHandlers) Refresh(w http.ResponseWriter, r *http.Request) {
	polled, err := h.CloudUsage.RunPollOnce(r.Context())
	if err != nil {
		WriteError(w, r, CodeInternal, "failed to refresh cloud usage: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"metrics_polled": polled})
}

type updateThresholdRequest struct {
	WarningPct  float64 `json:"warning_pct"`
	CriticalPct float64 `json:"critical_pct"`
}

func (h *CloudUsageHandlers) UpdateThreshold(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	var req updateThresholdRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, r, CodeValidation, "invalid request body")
		return
	}
	if req.WarningPct <= 0 || req.CriticalPct <= 0 || req.WarningPct >= req.CriticalPct {
		WriteError(w, r, CodeValidation, "warning_pct must be positive and less than critical_pct")
		return
	}
	if err := h.CloudUsage.UpdateThreshold(r.Context(), id, req.WarningPct, req.CriticalPct); err != nil {
		WriteError(w, r, CodeInternal, "failed to update threshold: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"status": "ok"})
}
