package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/google/uuid"

	"github.com/andipatti/feedmate/services/api/internal/domain/identity"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type AuthHandlers struct {
	Identity *identity.Service
}

type loginRequest struct {
	DeviceUUID string `json:"device_uuid"`
	Username   string `json:"username"`
	Password   string `json:"password"`
}

type tokenResponse struct {
	AccessToken  string   `json:"access_token"`
	RefreshToken string   `json:"refresh_token"`
	ExpiresIn    int64    `json:"expires_in"`
	TokenType    string   `json:"token_type"`
	UserID       string   `json:"user_id"`
	TenantID     string   `json:"tenant_id"`
	DisplayName  string   `json:"display_name,omitempty"`
	Permissions  []string `json:"permissions"`
}

func (h *AuthHandlers) Login(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	var req loginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	deviceUUID, err := uuid.Parse(req.DeviceUUID)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "device_uuid must be a valid UUID",
			ValidationDetail{Field: "device_uuid", Message: "must be a valid UUID"})
		return
	}
	if req.Username == "" || req.Password == "" {
		WriteError(w, reqID, CodeValidation, "username and password are required")
		return
	}

	result, err := h.Identity.Login(r.Context(), deviceUUID, req.Username, req.Password)
	if err != nil {
		switch {
		case errors.Is(err, identity.ErrInvalidCredentials):
			WriteError(w, reqID, CodeUnauthorized, "invalid username or password")
		case errors.Is(err, identity.ErrAccountLocked):
			WriteError(w, reqID, CodeForbidden, "account temporarily locked due to repeated failed logins")
		case errors.Is(err, identity.ErrDeviceNotActive):
			WriteError(w, reqID, CodeForbidden, "device is not registered or not active")
		default:
			WriteError(w, reqID, CodeInternal, "login failed: "+err.Error())
		}
		return
	}

	WriteJSON(w, http.StatusOK, tokenResponse{
		AccessToken:  result.AccessToken,
		RefreshToken: result.RefreshToken,
		ExpiresIn:    result.ExpiresIn,
		TokenType:    "Bearer",
		UserID:       result.UserID.String(),
		TenantID:     result.TenantID.String(),
		DisplayName:  result.DisplayName,
		Permissions:  result.Permissions,
	})
}

type refreshRequest struct {
	TenantID     string `json:"tenant_id"`
	RefreshToken string `json:"refresh_token"`
}

func (h *AuthHandlers) Refresh(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	var req refreshRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	tenantID, err := uuid.Parse(req.TenantID)
	if err != nil || req.RefreshToken == "" {
		WriteError(w, reqID, CodeValidation, "tenant_id and refresh_token are required")
		return
	}

	result, err := h.Identity.Refresh(r.Context(), tenantID, req.RefreshToken)
	if err != nil {
		WriteError(w, reqID, CodeUnauthorized, "refresh token invalid or expired")
		return
	}

	WriteJSON(w, http.StatusOK, tokenResponse{
		AccessToken:  result.AccessToken,
		RefreshToken: result.RefreshToken,
		ExpiresIn:    result.ExpiresIn,
		TokenType:    "Bearer",
		UserID:       result.UserID.String(),
		TenantID:     result.TenantID.String(),
		DisplayName:  result.DisplayName,
		Permissions:  result.Permissions,
	})
}

type logoutRequest struct {
	TenantID     string `json:"tenant_id"`
	RefreshToken string `json:"refresh_token"`
}

func (h *AuthHandlers) Logout(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	var req logoutRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	tenantID, err := uuid.Parse(req.TenantID)
	if err != nil || req.RefreshToken == "" {
		WriteError(w, reqID, CodeValidation, "tenant_id and refresh_token are required")
		return
	}
	if err := h.Identity.Logout(r.Context(), tenantID, req.RefreshToken); err != nil {
		WriteError(w, reqID, CodeInternal, "logout failed: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
