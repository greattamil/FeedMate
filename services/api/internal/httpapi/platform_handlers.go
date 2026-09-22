package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/andipatti/feedmate/services/api/internal/domain/platformadmin"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

// PlatformHandlers covers the super-admin control plane — a separate router
// group (see cmd/api/main.go) gated by middleware.RequirePlatform instead of
// the ordinary tenant RequireAuth/RequirePermission pair, since a platform
// admin has no tenant at all.
type PlatformHandlers struct {
	Platform *platformadmin.Service
}

type platformLoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type platformTokenResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int64  `json:"expires_in"`
	TokenType    string `json:"token_type"`
	DisplayName  string `json:"display_name,omitempty"`
}

func (h *PlatformHandlers) Login(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	var req platformLoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if req.Username == "" || req.Password == "" {
		WriteError(w, reqID, CodeValidation, "username and password are required")
		return
	}
	result, err := h.Platform.Login(r.Context(), req.Username, req.Password)
	if err != nil {
		if errors.Is(err, platformadmin.ErrInvalidCredentials) {
			WriteError(w, reqID, CodeUnauthorized, "invalid username or password")
			return
		}
		WriteError(w, reqID, CodeInternal, "login failed: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, platformTokenResponse{
		AccessToken: result.AccessToken, RefreshToken: result.RefreshToken,
		ExpiresIn: result.ExpiresIn, TokenType: "Bearer", DisplayName: result.DisplayName,
	})
}

type platformRefreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

func (h *PlatformHandlers) Refresh(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	var req platformRefreshRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.RefreshToken == "" {
		WriteError(w, reqID, CodeValidation, "refresh_token is required")
		return
	}
	result, err := h.Platform.Refresh(r.Context(), req.RefreshToken)
	if err != nil {
		WriteError(w, reqID, CodeUnauthorized, "refresh token invalid or expired")
		return
	}
	WriteJSON(w, http.StatusOK, platformTokenResponse{
		AccessToken: result.AccessToken, RefreshToken: result.RefreshToken,
		ExpiresIn: result.ExpiresIn, TokenType: "Bearer",
	})
}

func (h *PlatformHandlers) Logout(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	var req platformRefreshRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.RefreshToken == "" {
		WriteError(w, reqID, CodeValidation, "refresh_token is required")
		return
	}
	if err := h.Platform.Logout(r.Context(), req.RefreshToken); err != nil {
		WriteError(w, reqID, CodeInternal, "logout failed: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func tenantSummaryJSON(t platformadmin.TenantSummary) map[string]interface{} {
	out := map[string]interface{}{
		"id": t.ID.String(), "legal_name": t.LegalName, "city": t.City,
		"status": t.Status, "plan_code": t.PlanCode, "user_count": t.UserCount,
		"created_at": t.CreatedAt.Format(time.RFC3339),
	}
	if t.TradeName != nil {
		out["trade_name"] = *t.TradeName
	}
	if t.PlanExpiresAt != nil {
		out["plan_expires_at"] = t.PlanExpiresAt.Format(time.RFC3339)
	}
	return out
}

func (h *PlatformHandlers) ListTenants(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	tenants, err := h.Platform.ListTenants(r.Context())
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list tenants: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(tenants))
	for _, t := range tenants {
		out = append(out, tenantSummaryJSON(t))
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"tenants": out})
}

func tenantDetailJSON(d *platformadmin.TenantDetail) map[string]interface{} {
	out := tenantSummaryJSON(d.TenantSummary)
	out["address_line1"] = d.AddressLine1
	out["state_code"] = d.StateCode
	if d.Phone != nil {
		out["phone"] = *d.Phone
	}
	if d.Email != nil {
		out["email"] = *d.Email
	}
	if d.AppDisplayName != nil {
		out["app_display_name"] = *d.AppDisplayName
	}
	if d.LogoURL != nil {
		out["logo_url"] = *d.LogoURL
	}
	if d.PrimaryColor != nil {
		out["primary_color"] = *d.PrimaryColor
	}
	out["features"] = d.Features
	return out
}

func (h *PlatformHandlers) GetTenant(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	detail, err := h.Platform.GetTenant(r.Context(), id)
	if err != nil {
		if errors.Is(err, platformadmin.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "tenant not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to fetch tenant: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, tenantDetailJSON(detail))
}

type createTenantRequest struct {
	LegalName     string `json:"legal_name"`
	TradeName     string `json:"trade_name,omitempty"`
	AddressLine1  string `json:"address_line1"`
	City          string `json:"city"`
	StateCode     string `json:"state_code"`
	Phone         string `json:"phone,omitempty"`
	Email         string `json:"email,omitempty"`
	PlanCode      string `json:"plan_code,omitempty"`
	OwnerUsername string `json:"owner_username"`
	OwnerPassword string `json:"owner_password"`
	OwnerName     string `json:"owner_name"`
}

func (h *PlatformHandlers) CreateTenant(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	var req createTenantRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	tenantID, ownerUserID, err := h.Platform.CreateTenant(r.Context(), platformadmin.CreateTenantInput{
		LegalName: req.LegalName, TradeName: req.TradeName, AddressLine1: req.AddressLine1,
		City: req.City, StateCode: req.StateCode, Phone: req.Phone, Email: req.Email,
		PlanCode: req.PlanCode, OwnerUsername: req.OwnerUsername, OwnerPassword: req.OwnerPassword, OwnerName: req.OwnerName,
	})
	if err != nil {
		if errors.Is(err, platformadmin.ErrValidation) {
			WriteError(w, reqID, CodeValidation, err.Error())
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to create tenant: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusCreated, map[string]string{"tenant_id": tenantID.String(), "owner_user_id": ownerUserID.String()})
}

type setTenantStatusRequest struct {
	Status string `json:"status"`
}

func (h *PlatformHandlers) SetTenantStatus(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	var req setTenantStatusRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if err := h.Platform.SetTenantStatus(r.Context(), id, req.Status); err != nil {
		switch {
		case errors.Is(err, platformadmin.ErrValidation):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, platformadmin.ErrNotFound):
			WriteError(w, reqID, CodeNotFound, "tenant not found")
		default:
			WriteError(w, reqID, CodeInternal, "failed to update tenant status: "+err.Error())
		}
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type setTenantPlanRequest struct {
	PlanCode      string  `json:"plan_code"`
	PlanExpiresAt *string `json:"plan_expires_at,omitempty"`
}

func (h *PlatformHandlers) SetTenantPlan(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	var req setTenantPlanRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	var expiresAt *time.Time
	if req.PlanExpiresAt != nil && *req.PlanExpiresAt != "" {
		t, err := time.Parse(time.RFC3339, *req.PlanExpiresAt)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "plan_expires_at must be RFC3339")
			return
		}
		expiresAt = &t
	}
	if err := h.Platform.SetTenantPlan(r.Context(), id, req.PlanCode, expiresAt); err != nil {
		switch {
		case errors.Is(err, platformadmin.ErrValidation):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, platformadmin.ErrNotFound):
			WriteError(w, reqID, CodeNotFound, "tenant not found")
		default:
			WriteError(w, reqID, CodeInternal, "failed to update tenant plan: "+err.Error())
		}
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type setTenantBrandingRequest struct {
	AppDisplayName *string `json:"app_display_name,omitempty"`
	LogoURL        *string `json:"logo_url,omitempty"`
	PrimaryColor   *string `json:"primary_color,omitempty"`
}

func (h *PlatformHandlers) SetTenantBranding(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	var req setTenantBrandingRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if err := h.Platform.SetTenantBranding(r.Context(), id, req.AppDisplayName, req.LogoURL, req.PrimaryColor); err != nil {
		if errors.Is(err, platformadmin.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "tenant not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to update tenant branding: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type setTenantFeatureRequest struct {
	FeatureCode string `json:"feature_code"`
	Enabled     bool   `json:"enabled"`
}

func (h *PlatformHandlers) SetTenantFeature(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	var req setTenantFeatureRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if err := h.Platform.SetTenantFeature(r.Context(), id, req.FeatureCode, req.Enabled); err != nil {
		if errors.Is(err, platformadmin.ErrValidation) {
			WriteError(w, reqID, CodeValidation, err.Error())
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to update tenant feature: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func parsePlatformLimitOffset(r *http.Request) (limit, offset int) {
	limit, offset = 50, 0
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			limit = n
		}
	}
	if v := r.URL.Query().Get("offset"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			offset = n
		}
	}
	return limit, offset
}

func (h *PlatformHandlers) ListAuditLogs(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	limit, offset := parsePlatformLimitOffset(r)
	entries, err := h.Platform.ListAuditLogsAllTenants(r.Context(), limit, offset)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list audit logs: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(entries))
	for _, e := range entries {
		row := map[string]interface{}{
			"id": e.ID.String(), "action_code": e.ActionCode, "entity_type": e.EntityType,
			"created_at": e.CreatedAt.Format(time.RFC3339),
		}
		if e.TenantID != nil {
			row["tenant_id"] = e.TenantID.String()
		}
		if e.TenantName != nil {
			row["tenant_name"] = *e.TenantName
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
		out = append(out, row)
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"entries": out})
}

func (h *PlatformHandlers) ListErrorLogs(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	limit, offset := parsePlatformLimitOffset(r)
	entries, err := h.Platform.ListErrorLogs(r.Context(), limit, offset)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list error logs: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(entries))
	for _, e := range entries {
		row := map[string]interface{}{
			"id": e.ID.String(), "status_code": e.StatusCode, "message": e.Message,
			"created_at": e.CreatedAt.Format(time.RFC3339),
		}
		if e.RequestID != nil {
			row["request_id"] = e.RequestID.String()
		}
		out = append(out, row)
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"entries": out})
}

func brandingJSON(b *platformadmin.EffectiveBranding) map[string]interface{} {
	out := map[string]interface{}{"app_name": b.AppName, "app_tagline": b.AppTagline}
	if b.LogoURL != nil {
		out["logo_url"] = *b.LogoURL
	}
	if b.PrimaryColor != nil {
		out["primary_color"] = *b.PrimaryColor
	}
	return out
}

// GetBranding is deliberately unauthenticated — the login screen has no
// access token yet, so it can only identify itself by device_uuid (which
// may be absent, unrecognized, or belong to a tenant with no branding
// override; every one of those cases still returns the platform default,
// never an error) — see platformadmin.Service.ResolveBranding's doc comment.
func (h *PlatformHandlers) GetBranding(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	var deviceUUID *uuid.UUID
	if v := r.URL.Query().Get("device_uuid"); v != "" {
		if id, err := uuid.Parse(v); err == nil {
			deviceUUID = &id
		}
	}
	branding, err := h.Platform.ResolveBranding(r.Context(), deviceUUID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to resolve branding: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, brandingJSON(branding))
}

func (h *PlatformHandlers) GetPlatformSettings(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	settings, err := h.Platform.GetPlatformSettings(r.Context())
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to fetch platform settings: "+err.Error())
		return
	}
	out := map[string]interface{}{"app_name": settings.AppName, "app_tagline": settings.AppTagline}
	if settings.LogoURL != nil {
		out["logo_url"] = *settings.LogoURL
	}
	if settings.PrimaryColor != nil {
		out["primary_color"] = *settings.PrimaryColor
	}
	WriteJSON(w, http.StatusOK, out)
}

type updatePlatformSettingsRequest struct {
	AppName      string  `json:"app_name"`
	AppTagline   string  `json:"app_tagline"`
	LogoURL      *string `json:"logo_url,omitempty"`
	PrimaryColor *string `json:"primary_color,omitempty"`
}

func (h *PlatformHandlers) UpdatePlatformSettings(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	var req updatePlatformSettingsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if err := h.Platform.UpdatePlatformSettings(r.Context(), req.AppName, req.AppTagline, req.LogoURL, req.PrimaryColor); err != nil {
		if errors.Is(err, platformadmin.ErrValidation) {
			WriteError(w, reqID, CodeValidation, err.Error())
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to update platform settings: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
