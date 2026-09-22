package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/andipatti/feedmate/services/api/internal/domain/identity"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

// StaffHandlers covers user/role management — a separate struct from
// AuthHandlers (both wrap identity.Service) purely to keep login/session
// concerns and staff-administration concerns in separate files.
type StaffHandlers struct {
	Identity *identity.Service
}

type createUserRequest struct {
	Username    string   `json:"username"`
	Password    string   `json:"password"`
	DisplayName string   `json:"display_name"`
	Phone       string   `json:"phone,omitempty"`
	Email       string   `json:"email,omitempty"`
	RoleIDs     []string `json:"role_ids,omitempty"`
}

func userSummaryToJSON(u identity.UserSummary) map[string]interface{} {
	out := map[string]interface{}{
		"id":           u.ID.String(),
		"username":     u.Username,
		"display_name": u.DisplayName,
		"status":       u.Status,
	}
	if u.Phone != nil {
		out["phone"] = *u.Phone
	}
	if u.Email != nil {
		out["email"] = *u.Email
	}
	if u.LastLoginAt != nil {
		out["last_login_at"] = u.LastLoginAt.Format(time.RFC3339)
	}
	return out
}

// CreateUser registers a new staff account, optionally assigning it roles
// in the same request.
func (h *StaffHandlers) CreateUser(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	var req createUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	var roleIDs []uuid.UUID
	for _, s := range req.RoleIDs {
		id, err := uuid.Parse(s)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "role_ids must all be valid UUIDs")
			return
		}
		roleIDs = append(roleIDs, id)
	}

	userID, err := h.Identity.CreateUser(r.Context(), claims.TenantID, identity.CreateUserInput{
		Username: req.Username, Password: req.Password, DisplayName: req.DisplayName,
		Phone: req.Phone, Email: req.Email, RoleIDs: roleIDs,
	})
	if err != nil {
		switch {
		case errors.Is(err, identity.ErrValidation):
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

// ListUsers returns staff accounts, optionally filtered by a substring
// match on username/display name via the `q` query param.
func (h *StaffHandlers) ListUsers(w http.ResponseWriter, r *http.Request) {
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
	page, err := h.Identity.ListUsers(r.Context(), claims.TenantID, query, limit, offset)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list users: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(page.Users))
	for _, u := range page.Users {
		out = append(out, userSummaryToJSON(u))
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"users": out, "total": page.Total})
}

// GetUser returns one staff member's profile plus their currently assigned
// role ids.
func (h *StaffHandlers) GetUser(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid user id")
		return
	}
	detail, err := h.Identity.GetUserDetail(r.Context(), claims.TenantID, id)
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

type setUserStatusRequest struct {
	Active bool `json:"active"`
}

// SetUserStatus activates or deactivates a staff account — never a hard
// delete. Self-deactivation is explicitly rejected here (the service layer
// has no concept of "the caller", only the target user).
func (h *StaffHandlers) SetUserStatus(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid user id")
		return
	}
	if id == claims.UserID {
		WriteError(w, reqID, CodeValidation, "you cannot change your own account status")
		return
	}
	var req setUserStatusRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if err := h.Identity.SetUserStatus(r.Context(), claims.TenantID, id, req.Active); err != nil {
		if errors.Is(err, identity.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "user not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to update user status: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type updateUserRequest struct {
	DisplayName string `json:"display_name"`
	Phone       string `json:"phone,omitempty"`
	Email       string `json:"email,omitempty"`
}

// UpdateUser changes a staff member's profile fields (never username or
// password — see ResetUserPassword for the latter).
func (h *StaffHandlers) UpdateUser(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid user id")
		return
	}
	var req updateUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if err := h.Identity.UpdateUser(r.Context(), claims.TenantID, id, identity.UpdateUserInput{
		DisplayName: req.DisplayName, Phone: req.Phone, Email: req.Email,
	}); err != nil {
		switch {
		case errors.Is(err, identity.ErrValidation):
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

type resetUserPasswordRequest struct {
	NewPassword string `json:"new_password"`
}

// ResetUserPassword lets an admin set a new password for a staff account
// directly — there is no email/SMS self-service reset flow in this app, so
// a manager sets it and hands the new password to the staff member out of
// band.
func (h *StaffHandlers) ResetUserPassword(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid user id")
		return
	}
	var req resetUserPasswordRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if err := h.Identity.SetPassword(r.Context(), claims.TenantID, id, req.NewPassword); err != nil {
		switch {
		case errors.Is(err, identity.ErrValidation):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, identity.ErrNotFound):
			WriteError(w, reqID, CodeNotFound, "user not found")
		default:
			WriteError(w, reqID, CodeInternal, "failed to reset password: "+err.Error())
		}
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ListRoles returns every assignable role for the tenant (system defaults
// plus any tenant-defined custom roles), for the staff form's role picker.
func (h *StaffHandlers) ListRoles(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	roles, err := h.Identity.ListRoles(r.Context(), claims.TenantID)
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

type setUserRolesRequest struct {
	RoleIDs []string `json:"role_ids"`
}

// SetUserRoles replaces a user's full set of role assignments.
func (h *StaffHandlers) SetUserRoles(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
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
	if err := h.Identity.SetUserRoles(r.Context(), claims.TenantID, id, roleIDs); err != nil {
		if errors.Is(err, identity.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "user not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to update user roles: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
