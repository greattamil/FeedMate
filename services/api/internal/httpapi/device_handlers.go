package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/google/uuid"

	"github.com/andipatti/feedmate/services/api/internal/domain/devicepairing"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type DeviceHandlers struct {
	DevicePairing *devicepairing.Service
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
