package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/andipatti/feedmate/services/api/internal/domain/devicepairing"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type DeviceHandlers struct {
	DevicePairing *devicepairing.Service
}

// List returns registered devices newest-first, optionally filtered by a
// substring match on display name via the `q` query param.
func (h *DeviceHandlers) List(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	query := r.URL.Query().Get("q")
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
	page, err := h.DevicePairing.ListDevices(r.Context(), claims.TenantID, query, limit, offset)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list devices: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(page.Devices))
	for _, d := range page.Devices {
		row := map[string]interface{}{
			"id":             d.ID.String(),
			"device_uuid":    d.DeviceUUID.String(),
			"display_name":   d.DisplayName,
			"platform":       d.Platform,
			"status":         d.Status,
			"security_state": d.SecurityState,
			"registered_at":  d.RegisteredAt.Format(time.RFC3339),
		}
		if d.LastSeenAt != nil {
			row["last_seen_at"] = d.LastSeenAt.Format(time.RFC3339)
		}
		out = append(out, row)
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"devices": out, "total": page.Total})
}

type revokeDeviceRequest struct {
	Reason string `json:"reason,omitempty"`
}

// Revoke locks a device out immediately (see
// devicepairing.Service.RevokeDevice's doc comment): flips its status to
// REVOKED and invalidates every one of its still-valid refresh tokens.
func (h *DeviceHandlers) Revoke(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid device id")
		return
	}
	var req revokeDeviceRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if err := h.DevicePairing.RevokeDevice(r.Context(), claims.TenantID, id, claims.UserID, req.Reason); err != nil {
		if errors.Is(err, devicepairing.ErrDeviceNotFound) {
			WriteError(w, reqID, CodeNotFound, "device not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to revoke device: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// GeneratePairingCode is called by an authenticated user holding
// device.manage, from a device already paired to the tenant.
func (h *DeviceHandlers) GeneratePairingCode(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	result, err := h.DevicePairing.GeneratePairingCode(r.Context(), claims.TenantID, claims.UserID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to generate pairing code: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusCreated, map[string]string{
		"code":       result.Code,
		"expires_at": result.ExpiresAt.Format("2006-01-02T15:04:05Z07:00"),
	})
}

type registerDeviceRequest struct {
	Code        string `json:"code"`
	DeviceUUID  string `json:"device_uuid"`
	DisplayName string `json:"display_name"`
	Platform    string `json:"platform,omitempty"`
}

// RegisterDevice is deliberately NOT behind RequireAuth — a brand new device
// has no access token yet. Its only credential is the short-lived pairing
// code a legitimate tenant user generated on an already-paired device (see
// GeneratePairingCode) and communicated out of band (read aloud, shown on
// screen, etc.) — never trust device_uuid/display_name alone.
func (h *DeviceHandlers) RegisterDevice(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	var req registerDeviceRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	deviceUUID, err := uuid.Parse(req.DeviceUUID)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "device_uuid must be a valid UUID")
		return
	}
	if req.DisplayName == "" {
		WriteError(w, reqID, CodeValidation, "display_name is required")
		return
	}
	platform := req.Platform
	if platform == "" {
		platform = "OTHER"
	}

	result, err := h.DevicePairing.RegisterDevice(r.Context(), req.Code, deviceUUID, req.DisplayName, platform)
	if err != nil {
		switch {
		case errors.Is(err, devicepairing.ErrCodeInvalid):
			WriteError(w, reqID, CodeValidation, "pairing code is invalid, expired, or already used")
		case errors.Is(err, devicepairing.ErrValidation):
			WriteError(w, reqID, CodeValidation, err.Error())
		default:
			WriteError(w, reqID, CodeInternal, "failed to register device: "+err.Error())
		}
		return
	}
	WriteJSON(w, http.StatusCreated, map[string]string{
		"tenant_id": result.TenantID.String(),
		"status":    "ACTIVE",
	})
}
