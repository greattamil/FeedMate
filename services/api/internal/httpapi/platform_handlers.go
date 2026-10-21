package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/domain/devicepairing"
	"github.com/andipatti/feedmate/services/api/internal/domain/identity"
	"github.com/andipatti/feedmate/services/api/internal/domain/platformadmin"
	"github.com/andipatti/feedmate/services/api/internal/domain/subscription"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

// PlatformHandlers covers the super-admin control plane — a separate router
// group (see cmd/api/main.go) gated by middleware.RequirePlatform instead of
// the ordinary tenant RequireAuth/RequirePermission pair, since a platform
// admin has no tenant at all.
type PlatformHandlers struct {
	Platform     *platformadmin.Service
	Subscription *subscription.Service
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
	if d.GSTIN != nil {
		out["gstin"] = *d.GSTIN
	}
	if d.FSSAILicenseNo != nil {
		out["fssai_license_no"] = *d.FSSAILicenseNo
	}
	if d.AddressLine2 != nil {
		out["address_line2"] = *d.AddressLine2
	}
	if d.District != nil {
		out["district"] = *d.District
	}
	if d.PostalCode != nil {
		out["postal_code"] = *d.PostalCode
	}
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

type updateTenantRequest struct {
	LegalName      string `json:"legal_name"`
	TradeName      string `json:"trade_name,omitempty"`
	GSTIN          string `json:"gstin,omitempty"`
	FSSAILicenseNo string `json:"fssai_license_no,omitempty"`
	AddressLine1   string `json:"address_line1"`
	AddressLine2   string `json:"address_line2,omitempty"`
	City           string `json:"city"`
	District       string `json:"district,omitempty"`
	StateCode      string `json:"state_code"`
	PostalCode     string `json:"postal_code,omitempty"`
	Phone          string `json:"phone,omitempty"`
	Email          string `json:"email,omitempty"`
}

// UpdateTenant corrects a tenant's legal/contact identity fields — the
// full-edit capability CreateTenant alone never provided.
func (h *PlatformHandlers) UpdateTenant(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	var req updateTenantRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	err = h.Platform.UpdateTenant(r.Context(), id, platformadmin.UpdateTenantInput{
		LegalName: req.LegalName, TradeName: req.TradeName, GSTIN: req.GSTIN, FSSAILicenseNo: req.FSSAILicenseNo,
		AddressLine1: req.AddressLine1, AddressLine2: req.AddressLine2, City: req.City,
		District: req.District, StateCode: req.StateCode, PostalCode: req.PostalCode,
		Phone: req.Phone, Email: req.Email,
	})
	if err != nil {
		switch {
		case errors.Is(err, platformadmin.ErrValidation):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, platformadmin.ErrNotFound):
			WriteError(w, reqID, CodeNotFound, "tenant not found")
		default:
			WriteError(w, reqID, CodeInternal, "failed to update tenant: "+err.Error())
		}
		return
	}
	w.WriteHeader(http.StatusNoContent)
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

// --- Tenant user management from platform admin — closes the gap that
// required hand-written SQL against production this session for a tenant
// owner's forgotten password. ---

func (h *PlatformHandlers) ListTenantUsers(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	tenantID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	query := r.URL.Query().Get("q")
	limit, offset := parsePlatformLimitOffset(r)
	page, err := h.Platform.ListTenantUsers(r.Context(), tenantID, query, limit, offset)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list tenant users: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(page.Users))
	for _, u := range page.Users {
		out = append(out, userSummaryToJSON(u))
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"users": out, "total": page.Total})
}

func (h *PlatformHandlers) GetTenantUser(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	tenantID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	userID, err := uuid.Parse(chi.URLParam(r, "userId"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid user id")
		return
	}
	detail, err := h.Platform.GetTenantUserDetail(r.Context(), tenantID, userID)
	if err != nil {
		if errors.Is(err, identity.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "user not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to fetch user: "+err.Error())
		return
	}
	resp := userSummaryToJSON(detail.User)
	roleIDs := make([]string, 0, len(detail.RoleIDs))
	for _, id := range detail.RoleIDs {
		roleIDs = append(roleIDs, id.String())
	}
	resp["role_ids"] = roleIDs
	WriteJSON(w, http.StatusOK, resp)
}

func (h *PlatformHandlers) CreateTenantUser(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	tenantID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	var req createUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	var roleIDs []uuid.UUID
	for _, s := range req.RoleIDs {
		rid, err := uuid.Parse(s)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "role_ids must all be valid UUIDs")
			return
		}
		roleIDs = append(roleIDs, rid)
	}
	userID, err := h.Platform.CreateTenantUser(r.Context(), tenantID, identity.CreateUserInput{
		Username: req.Username, Password: req.Password, DisplayName: req.DisplayName,
		Phone: req.Phone, Email: req.Email, RoleIDs: roleIDs,
	})
	if err != nil {
		switch {
		case errors.Is(err, platformadmin.ErrValidation):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, identity.ErrUsernameTaken):
			WriteError(w, reqID, CodeConflict, err.Error())
		default:
			WriteError(w, reqID, CodeInternal, "failed to create user: "+err.Error())
		}
		return
	}
	WriteJSON(w, http.StatusCreated, map[string]string{"id": userID.String()})
}

func (h *PlatformHandlers) UpdateTenantUser(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	tenantID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	userID, err := uuid.Parse(chi.URLParam(r, "userId"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid user id")
		return
	}
	var req updateUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if err := h.Platform.UpdateTenantUser(r.Context(), tenantID, userID, identity.UpdateUserInput{
		DisplayName: req.DisplayName, Phone: req.Phone, Email: req.Email,
	}); err != nil {
		switch {
		case errors.Is(err, platformadmin.ErrValidation):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, identity.ErrNotFound):
			WriteError(w, reqID, CodeNotFound, "user not found")
		default:
			WriteError(w, reqID, CodeInternal, "failed to update user: "+err.Error())
		}
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *PlatformHandlers) SetTenantUserStatus(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	tenantID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	userID, err := uuid.Parse(chi.URLParam(r, "userId"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid user id")
		return
	}
	var req setUserStatusRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if err := h.Platform.SetTenantUserStatus(r.Context(), tenantID, userID, req.Active); err != nil {
		if errors.Is(err, identity.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "user not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to update user status: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ResetTenantUserPassword generates a brand-new password server-side and
// returns it exactly once — the platform admin reads it off-screen and
// relays it to the tenant out of band. This is the proper replacement for
// the hand-written SQL password resets this session had to perform
// directly against production.
func (h *PlatformHandlers) ResetTenantUserPassword(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	tenantID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	userID, err := uuid.Parse(chi.URLParam(r, "userId"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid user id")
		return
	}
	newPassword, err := h.Platform.ResetTenantUserPassword(r.Context(), tenantID, userID, claims.UserID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to reset password: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]string{"new_password": newPassword})
}

func (h *PlatformHandlers) ListTenantUserRoles(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	tenantID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	roles, err := h.Platform.ListTenantUserRoles(r.Context(), tenantID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list roles: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(roles))
	for _, role := range roles {
		row := map[string]interface{}{"id": role.ID.String(), "name": role.Name, "is_system_role": role.IsSystemRole}
		if role.Description != nil {
			row["description"] = *role.Description
		}
		out = append(out, row)
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"roles": out})
}

func (h *PlatformHandlers) SetTenantUserRoles(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	tenantID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	userID, err := uuid.Parse(chi.URLParam(r, "userId"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid user id")
		return
	}
	var req setUserRolesRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	var roleIDs []uuid.UUID
	for _, s := range req.RoleIDs {
		rid, err := uuid.Parse(s)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "role_ids must all be valid UUIDs")
			return
		}
		roleIDs = append(roleIDs, rid)
	}
	if err := h.Platform.SetTenantUserRoles(r.Context(), tenantID, userID, roleIDs); err != nil {
		if errors.Is(err, identity.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "user not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to update user roles: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// --- Tenant device management from platform admin. ---

func (h *PlatformHandlers) ListTenantDevices(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	tenantID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	query := r.URL.Query().Get("q")
	limit, offset := parsePlatformLimitOffset(r)
	page, err := h.Platform.ListTenantDevices(r.Context(), tenantID, query, limit, offset)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list devices: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(page.Devices))
	for _, d := range page.Devices {
		out = append(out, deviceRowJSON(d))
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"devices": out, "total": page.Total})
}

func (h *PlatformHandlers) RevokeTenantDevice(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	tenantID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	deviceID, err := uuid.Parse(chi.URLParam(r, "deviceId"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid device id")
		return
	}
	var req revokeDeviceRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if err := h.Platform.RevokeTenantDevice(r.Context(), tenantID, deviceID, claims.UserID, req.Reason); err != nil {
		if errors.Is(err, devicepairing.ErrDeviceNotFound) {
			WriteError(w, reqID, CodeNotFound, "device not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to revoke device: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// GeneratePairingCodeForTenant lets a platform admin generate a device
// pairing code for any tenant directly — the explicit, named gap this phase
// closes: tenants repeatedly forget to generate their own, and the
// workaround until now was hand-inserting a row via SQL directly against
// production.
func (h *PlatformHandlers) GeneratePairingCodeForTenant(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	tenantID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	result, err := h.Platform.GeneratePairingCodeForTenant(r.Context(), tenantID, claims.UserID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to generate pairing code: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusCreated, map[string]string{
		"code":       result.Code,
		"expires_at": result.ExpiresAt.Format("2006-01-02T15:04:05Z07:00"),
	})
}

// --- Subscription/billing: a plan catalogue, each tenant's current
// subscription state, and manually-recorded payments (no payment gateway —
// see subscription.Service.RecordManualPayment's doc comment). ---

func planJSON(p subscription.Plan) map[string]interface{} {
	return map[string]interface{}{
		"id": p.ID.String(), "code": p.Code, "name": p.Name,
		"price": p.Price.StringFixed(2), "currency_code": p.CurrencyCode,
		"billing_period": p.BillingPeriod, "grace_period_days": p.GracePeriodDays, "active": p.Active,
	}
}

func (h *PlatformHandlers) ListPlans(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	plans, err := h.Subscription.ListPlans(r.Context())
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list plans: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(plans))
	for _, p := range plans {
		out = append(out, planJSON(p))
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"plans": out})
}

type createPlanRequest struct {
	Code            string `json:"code"`
	Name            string `json:"name"`
	Price           string `json:"price"`
	GracePeriodDays int    `json:"grace_period_days"`
}

func (h *PlatformHandlers) CreatePlan(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	var req createPlanRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	price, err := decimal.NewFromString(req.Price)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "price must be a valid decimal")
		return
	}
	id, err := h.Subscription.CreatePlan(r.Context(), subscription.CreatePlanInput{
		Code: req.Code, Name: req.Name, Price: price, GracePeriodDays: req.GracePeriodDays,
	})
	if err != nil {
		if errors.Is(err, subscription.ErrValidation) {
			WriteError(w, reqID, CodeValidation, err.Error())
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to create plan: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusCreated, map[string]string{"id": id.String()})
}

type updatePlanRequest struct {
	Name            string `json:"name"`
	Price           string `json:"price"`
	GracePeriodDays int    `json:"grace_period_days"`
	Active          bool   `json:"active"`
}

func (h *PlatformHandlers) UpdatePlan(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid plan id")
		return
	}
	var req updatePlanRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	price, err := decimal.NewFromString(req.Price)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "price must be a valid decimal")
		return
	}
	if err := h.Subscription.UpdatePlan(r.Context(), id, subscription.UpdatePlanInput{
		Name: req.Name, Price: price, GracePeriodDays: req.GracePeriodDays, Active: req.Active,
	}); err != nil {
		switch {
		case errors.Is(err, subscription.ErrValidation):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, subscription.ErrNotFound):
			WriteError(w, reqID, CodeNotFound, "plan not found")
		default:
			WriteError(w, reqID, CodeInternal, "failed to update plan: "+err.Error())
		}
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func tenantSubscriptionJSON(s *subscription.TenantSubscription) map[string]interface{} {
	out := map[string]interface{}{
		"id": s.ID.String(), "tenant_id": s.TenantID.String(), "plan_id": s.PlanID.String(),
		"plan_code": s.PlanCode, "plan_name": s.PlanName, "plan_price": s.PlanPrice.StringFixed(2),
		"status":                      s.Status,
		"current_period_start":        s.CurrentPeriodStart.Format("2006-01-02"),
		"current_period_end":          s.CurrentPeriodEnd.Format("2006-01-02"),
		"effective_grace_period_days": s.EffectiveGraceDays,
	}
	if s.GracePeriodDays != nil {
		out["grace_period_days_override"] = *s.GracePeriodDays
	}
	if s.PastDueSince != nil {
		out["past_due_since"] = s.PastDueSince.Format(time.RFC3339)
	}
	return out
}

func (h *PlatformHandlers) GetTenantSubscription(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	tenantID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	sub, err := h.Subscription.GetTenantSubscription(r.Context(), tenantID)
	if err != nil {
		if errors.Is(err, subscription.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "tenant has no subscription assigned yet")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to fetch subscription: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, tenantSubscriptionJSON(sub))
}

type setTenantSubscriptionPlanRequest struct {
	PlanID      string  `json:"plan_id"`
	PeriodStart *string `json:"period_start,omitempty"`
}

func (h *PlatformHandlers) SetTenantSubscriptionPlan(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	tenantID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	var req setTenantSubscriptionPlanRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	planID, err := uuid.Parse(req.PlanID)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "plan_id must be a valid UUID")
		return
	}
	var periodStart *time.Time
	if req.PeriodStart != nil && *req.PeriodStart != "" {
		t, err := time.Parse("2006-01-02", *req.PeriodStart)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "period_start must be YYYY-MM-DD")
			return
		}
		periodStart = &t
	}
	if err := h.Subscription.SetTenantPlan(r.Context(), tenantID, planID, periodStart); err != nil {
		if errors.Is(err, subscription.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "plan not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to set tenant plan: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type recordSubscriptionPaymentRequest struct {
	Amount         string `json:"amount"`
	Method         string `json:"method"`
	Reference      string `json:"reference,omitempty"`
	Notes          string `json:"notes,omitempty"`
	IdempotencyKey string `json:"idempotency_key"`
}

// RecordSubscriptionPayment is the manual-recording path — no payment
// gateway: the platform admin collects payment out of band (UPI/bank
// transfer/cash) and records it here, the same trust model as the
// existing customer-receipt feature.
func (h *PlatformHandlers) RecordSubscriptionPayment(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	tenantID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	var req recordSubscriptionPaymentRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	amount, err := decimal.NewFromString(req.Amount)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "amount must be a valid decimal")
		return
	}
	result, err := h.Subscription.RecordManualPayment(r.Context(), tenantID, subscription.RecordPaymentInput{
		Amount: amount, Method: req.Method, Reference: req.Reference, Notes: req.Notes,
		IdempotencyKey: req.IdempotencyKey, PlatformAdminID: claims.UserID,
	})
	if err != nil {
		switch {
		case errors.Is(err, subscription.ErrValidation):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, subscription.ErrNotFound):
			WriteError(w, reqID, CodeNotFound, "tenant has no subscription assigned yet")
		default:
			WriteError(w, reqID, CodeInternal, "failed to record payment: "+err.Error())
		}
		return
	}
	WriteJSON(w, http.StatusCreated, map[string]interface{}{"payment_id": result.PaymentID.String(), "duplicate": result.Duplicate})
}

func (h *PlatformHandlers) ListBillingHistory(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	tenantID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid tenant id")
		return
	}
	limit, offset := parsePlatformLimitOffset(r)
	entries, total, err := h.Subscription.ListBillingHistory(r.Context(), tenantID, limit, offset)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list billing history: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(entries))
	for _, e := range entries {
		row := map[string]interface{}{
			"id": e.ID.String(), "amount": e.Amount.StringFixed(2),
			"period_start": e.PeriodStart.Format("2006-01-02"), "period_end": e.PeriodEnd.Format("2006-01-02"),
			"method": e.Method, "paid_at": e.PaidAt.Format(time.RFC3339),
		}
		if e.Reference != nil {
			row["reference"] = *e.Reference
		}
		if e.Notes != nil {
			row["notes"] = *e.Notes
		}
		out = append(out, row)
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"payments": out, "total": total})
}
