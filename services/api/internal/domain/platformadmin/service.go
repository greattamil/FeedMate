// Package platformadmin implements the super-admin control plane: managing
// every tenant (provisioning, suspension, plan/feature/whitelabel config)
// and viewing cross-tenant audit and error logs. Deliberately separate from
// identity.Service — a platform admin has no tenant, no device, and none of
// identity.Login's device→tenant resolution applies. Every DB call here
// runs on dbctx.DB.WithAdminTx, since by definition there is no single
// tenant to scope a transaction to.
package platformadmin

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/auth"
	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/devicepairing"
	"github.com/andipatti/feedmate/services/api/internal/domain/identity"
)

var (
	ErrInvalidCredentials  = errors.New("invalid credentials")
	ErrValidation          = errors.New("validation error")
	ErrRefreshTokenInvalid = errors.New("refresh token invalid or expired")
)

type Service struct {
	db         *dbctx.DB
	signingKey string
	accessTTL  time.Duration
	refreshTTL time.Duration
	bcryptCost int
}

func NewService(db *dbctx.DB, signingKey string, accessTTL, refreshTTL time.Duration, bcryptCost int) *Service {
	return &Service{db: db, signingKey: signingKey, accessTTL: accessTTL, refreshTTL: refreshTTL, bcryptCost: bcryptCost}
}

type LoginResult struct {
	AccessToken  string
	RefreshToken string
	ExpiresIn    int64
	DisplayName  string
}

func (s *Service) Login(ctx context.Context, username, password string) (*LoginResult, error) {
	var result *LoginResult
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		admin, err := FindPlatformAdminByUsername(ctx, tx, username)
		if err != nil {
			if errors.Is(err, ErrNotFound) {
				return ErrInvalidCredentials
			}
			return err
		}
		if admin.Status != "ACTIVE" {
			return ErrInvalidCredentials
		}
		if !auth.VerifyPassword(admin.PasswordHash, password) {
			return ErrInvalidCredentials
		}
		refreshToken, err := auth.GenerateOpaqueToken()
		if err != nil {
			return fmt.Errorf("generate token: %w", err)
		}
		if err := CreateSession(ctx, tx, admin.ID, auth.HashRefreshToken(refreshToken), time.Now().Add(s.refreshTTL)); err != nil {
			return fmt.Errorf("create session: %w", err)
		}
		accessToken, err := auth.IssuePlatformAccessToken(s.signingKey, admin.ID, s.accessTTL)
		if err != nil {
			return err
		}
		result = &LoginResult{
			AccessToken:  accessToken,
			RefreshToken: refreshToken,
			ExpiresIn:    int64(s.accessTTL.Seconds()),
			DisplayName:  admin.DisplayName,
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return result, nil
}

func (s *Service) Refresh(ctx context.Context, refreshToken string) (*LoginResult, error) {
	hash := auth.HashRefreshToken(refreshToken)
	var result *LoginResult
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		adminID, err := ResolveSession(ctx, tx, hash)
		if err != nil {
			if errors.Is(err, ErrNotFound) {
				return ErrRefreshTokenInvalid
			}
			return err
		}
		if err := RevokeSession(ctx, tx, hash); err != nil {
			return err
		}
		newRefresh, err := auth.GenerateOpaqueToken()
		if err != nil {
			return fmt.Errorf("generate token: %w", err)
		}
		if err := CreateSession(ctx, tx, adminID, auth.HashRefreshToken(newRefresh), time.Now().Add(s.refreshTTL)); err != nil {
			return fmt.Errorf("create session: %w", err)
		}
		accessToken, err := auth.IssuePlatformAccessToken(s.signingKey, adminID, s.accessTTL)
		if err != nil {
			return err
		}
		result = &LoginResult{AccessToken: accessToken, RefreshToken: newRefresh, ExpiresIn: int64(s.accessTTL.Seconds())}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return result, nil
}

func (s *Service) Logout(ctx context.Context, refreshToken string) error {
	return s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		return RevokeSession(ctx, tx, auth.HashRefreshToken(refreshToken))
	})
}

func (s *Service) ListTenants(ctx context.Context) ([]TenantSummary, error) {
	var out []TenantSummary
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = ListTenants(ctx, tx)
		return err
	})
	return out, err
}

func (s *Service) GetTenant(ctx context.Context, id uuid.UUID) (*TenantDetail, error) {
	var out *TenantDetail
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = GetTenant(ctx, tx, id)
		return err
	})
	return out, err
}

var validTenantStatuses = map[string]bool{"ACTIVE": true, "SUSPENDED": true, "CLOSED": true}

func (s *Service) SetTenantStatus(ctx context.Context, id uuid.UUID, status string) error {
	if !validTenantStatuses[status] {
		return fmt.Errorf("%w: status must be one of ACTIVE, SUSPENDED, CLOSED", ErrValidation)
	}
	return s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		return SetTenantStatus(ctx, tx, id, status)
	})
}

func (s *Service) SetTenantPlan(ctx context.Context, id uuid.UUID, planCode string, expiresAt *time.Time) error {
	if planCode == "" {
		return fmt.Errorf("%w: plan_code is required", ErrValidation)
	}
	return s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		return SetTenantPlan(ctx, tx, id, planCode, expiresAt)
	})
}

func (s *Service) SetTenantBranding(ctx context.Context, id uuid.UUID, appDisplayName, logoURL, primaryColor *string) error {
	return s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		return SetTenantBranding(ctx, tx, id, appDisplayName, logoURL, primaryColor)
	})
}

func (s *Service) SetTenantFeature(ctx context.Context, tenantID uuid.UUID, featureCode string, enabled bool) error {
	if featureCode == "" {
		return fmt.Errorf("%w: feature_code is required", ErrValidation)
	}
	return s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		return SetTenantFeature(ctx, tx, tenantID, featureCode, enabled)
	})
}

// CreateTenant provisions a brand-new tenant end-to-end (see
// CreateTenantInput's doc comment) and returns its id and the Owner user's
// id. Everything a client needs to start using the app in one atomic
// transaction — no follow-up manual SQL required.
func (s *Service) CreateTenant(ctx context.Context, in CreateTenantInput) (tenantID, ownerUserID uuid.UUID, err error) {
	if in.LegalName == "" {
		return uuid.Nil, uuid.Nil, fmt.Errorf("%w: legal_name is required", ErrValidation)
	}
	if in.AddressLine1 == "" || in.City == "" || in.StateCode == "" {
		return uuid.Nil, uuid.Nil, fmt.Errorf("%w: address_line1, city, and state_code are required", ErrValidation)
	}
	if in.OwnerUsername == "" || len(in.OwnerPassword) < 8 || in.OwnerName == "" {
		return uuid.Nil, uuid.Nil, fmt.Errorf("%w: owner_username, owner_name, and an owner_password of at least 8 characters are required", ErrValidation)
	}
	if in.PlanCode == "" {
		in.PlanCode = "TRIAL"
	}
	passwordHash, err := auth.HashPassword(in.OwnerPassword, s.bcryptCost)
	if err != nil {
		return uuid.Nil, uuid.Nil, fmt.Errorf("hash password: %w", err)
	}

	now := time.Now()
	fyStart, fyEnd, fyLabel := indianFinancialYear(now)

	err = s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		id, err := InsertTenant(ctx, tx, in)
		if err != nil {
			return fmt.Errorf("insert tenant: %w", err)
		}
		tenantID = id

		if err := InsertTenantSettings(ctx, tx, id); err != nil {
			return fmt.Errorf("insert tenant settings: %w", err)
		}

		roleID, err := InsertOwnerRoleWithAllPermissions(ctx, tx, id)
		if err != nil {
			return fmt.Errorf("insert owner role: %w", err)
		}

		fyID, err := InsertFinancialYear(ctx, tx, id, fyLabel, fyStart, fyEnd)
		if err != nil {
			return fmt.Errorf("insert financial year: %w", err)
		}

		for docType, prefix := range map[string]string{
			"INVOICE": "INV-", "GRN": "GRN-", "RETURN": "RET-", "CONTRA": "CNT-",
		} {
			if err := InsertDocumentSeries(ctx, tx, id, fyID, docType, prefix); err != nil {
				return fmt.Errorf("insert %s document series: %w", docType, err)
			}
		}

		userID, err := InsertOwnerUser(ctx, tx, id, roleID, in.OwnerUsername, passwordHash, in.OwnerName)
		if err != nil {
			return fmt.Errorf("insert owner user: %w", err)
		}
		ownerUserID = userID
		return nil
	})
	if err != nil {
		return uuid.Nil, uuid.Nil, err
	}
	return tenantID, ownerUserID, nil
}

// UpdateTenant corrects a tenant's legal/contact identity fields after
// creation — CreateTenant is the only way these were ever set before this,
// with no way to fix a typo or update an address afterward.
func (s *Service) UpdateTenant(ctx context.Context, id uuid.UUID, in UpdateTenantInput) error {
	if in.LegalName == "" {
		return fmt.Errorf("%w: legal_name is required", ErrValidation)
	}
	if in.AddressLine1 == "" || in.City == "" || in.StateCode == "" {
		return fmt.Errorf("%w: address_line1, city, and state_code are required", ErrValidation)
	}
	return s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		return UpdateTenant(ctx, tx, id, in)
	})
}

// --- Tenant user management (platform admin acting on one tenant's own
// staff accounts, without impersonating a tenant user or needing one to be
// logged in — see dbctx.WithAdminTenantTx's doc comment for why admin_mode
// must stay off here). Each method is a thin wrapper around identity
// package's repository-level functions (not identity.Service, which
// hardcodes the app_user pool via WithTenantTx) replicating the same thin
// validation identity.Service's own methods already do. ---

func (s *Service) ListTenantUsers(ctx context.Context, tenantID uuid.UUID, query string, limit, offset int) (*identity.UserListPage, error) {
	var page identity.UserListPage
	err := s.db.WithAdminTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		users, total, err := identity.ListUsers(ctx, tx, query, limit, offset)
		if err != nil {
			return err
		}
		page.Users = users
		page.Total = total
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &page, nil
}

func (s *Service) GetTenantUserDetail(ctx context.Context, tenantID, userID uuid.UUID) (*identity.UserDetail, error) {
	var detail identity.UserDetail
	err := s.db.WithAdminTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		user, err := identity.GetUserSummaryByID(ctx, tx, userID)
		if err != nil {
			return err
		}
		detail.User = *user
		roleIDs, err := identity.ListRolesForUser(ctx, tx, userID)
		if err != nil {
			return err
		}
		detail.RoleIDs = roleIDs
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &detail, nil
}

// CreateTenantUser registers a new staff account for a tenant — the same
// shape as identity.Service.CreateUser, reachable without that tenant's own
// user being logged in.
func (s *Service) CreateTenantUser(ctx context.Context, tenantID uuid.UUID, in identity.CreateUserInput) (uuid.UUID, error) {
	if in.Username == "" {
		return uuid.Nil, fmt.Errorf("%w: username is required", ErrValidation)
	}
	if in.DisplayName == "" {
		return uuid.Nil, fmt.Errorf("%w: display_name is required", ErrValidation)
	}
	if len(in.Password) < 8 {
		return uuid.Nil, fmt.Errorf("%w: password must be at least 8 characters", ErrValidation)
	}
	hash, err := auth.HashPassword(in.Password, s.bcryptCost)
	if err != nil {
		return uuid.Nil, fmt.Errorf("hash password: %w", err)
	}

	var userID uuid.UUID
	err = s.db.WithAdminTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		if _, err := identity.FindUserByUsername(ctx, tx, in.Username); err == nil {
			return identity.ErrUsernameTaken
		} else if !errors.Is(err, identity.ErrNotFound) {
			return err
		}
		id, err := identity.InsertUser(ctx, tx, tenantID, in.Username, hash, in.DisplayName, in.Phone, in.Email)
		if err != nil {
			return fmt.Errorf("insert user: %w", err)
		}
		for _, roleID := range in.RoleIDs {
			if err := identity.AssignRole(ctx, tx, tenantID, id, roleID); err != nil {
				return fmt.Errorf("assign role %s: %w", roleID, err)
			}
		}
		userID = id
		return nil
	})
	if err != nil {
		return uuid.Nil, err
	}
	return userID, nil
}

func (s *Service) UpdateTenantUser(ctx context.Context, tenantID, userID uuid.UUID, in identity.UpdateUserInput) error {
	if in.DisplayName == "" {
		return fmt.Errorf("%w: display_name is required", ErrValidation)
	}
	return s.db.WithAdminTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		return identity.UpdateUser(ctx, tx, userID, in.DisplayName, in.Phone, in.Email)
	})
}

func (s *Service) SetTenantUserStatus(ctx context.Context, tenantID, userID uuid.UUID, active bool) error {
	status := "ACTIVE"
	if !active {
		status = "DISABLED"
	}
	return s.db.WithAdminTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		return identity.SetUserStatus(ctx, tx, userID, status)
	})
}

// generateTempPassword produces a random, readable one-time password for a
// platform-admin-initiated reset — same alphabet style as
// devicepairing.GenerateCode (no visually ambiguous characters), but longer
// since this is a password a human types once then should change, not a
// short code read aloud between two screens.
func generateTempPassword() (string, error) {
	const alphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz"
	const length = 14
	var b strings.Builder
	for i := 0; i < length; i++ {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(alphabet))))
		if err != nil {
			return "", fmt.Errorf("generate temp password: %w", err)
		}
		b.WriteByte(alphabet[n.Int64()])
	}
	return b.String(), nil
}

// ResetTenantUserPassword overwrites a staff account's password with a
// freshly generated one and returns it exactly once — the caller (HTTP
// handler) must show it to the platform admin and never log or persist it
// elsewhere, the same "shown once" discipline as a device pairing code.
// This closes the exact gap that required hand-written SQL password resets
// against production earlier this session.
func (s *Service) ResetTenantUserPassword(ctx context.Context, tenantID, userID, platformAdminID uuid.UUID) (string, error) {
	newPassword, err := generateTempPassword()
	if err != nil {
		return "", err
	}
	hash, err := auth.HashPassword(newPassword, s.bcryptCost)
	if err != nil {
		return "", fmt.Errorf("hash password: %w", err)
	}
	err = s.db.WithAdminTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		if err := identity.SetPasswordHash(ctx, tx, userID, hash); err != nil {
			return err
		}
		return InsertCrossTenantAuditLog(ctx, tx, tenantID, platformAdminID, "USER_PASSWORD_RESET_BY_PLATFORM_ADMIN", "user", &userID, "", nil)
	})
	if err != nil {
		return "", err
	}
	return newPassword, nil
}

func (s *Service) ListTenantUserRoles(ctx context.Context, tenantID uuid.UUID) ([]identity.Role, error) {
	var roles []identity.Role
	err := s.db.WithAdminTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		roles, err = identity.ListRoles(ctx, tx)
		return err
	})
	return roles, err
}

func (s *Service) SetTenantUserRoles(ctx context.Context, tenantID, userID uuid.UUID, roleIDs []uuid.UUID) error {
	return s.db.WithAdminTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		if _, err := identity.GetUserByID(ctx, tx, userID); err != nil {
			return err
		}
		existing, err := identity.ListRolesForUser(ctx, tx, userID)
		if err != nil {
			return err
		}
		desired := make(map[uuid.UUID]bool, len(roleIDs))
		for _, id := range roleIDs {
			desired[id] = true
		}
		current := make(map[uuid.UUID]bool, len(existing))
		for _, id := range existing {
			current[id] = true
		}
		for _, id := range existing {
			if !desired[id] {
				if err := identity.RevokeRole(ctx, tx, userID, id); err != nil {
					return err
				}
			}
		}
		for _, id := range roleIDs {
			if !current[id] {
				if err := identity.AssignRole(ctx, tx, tenantID, userID, id); err != nil {
					return err
				}
			}
		}
		return nil
	})
}

// --- Tenant device management (same WithAdminTenantTx mechanism as user
// management above). ---

func (s *Service) ListTenantDevices(ctx context.Context, tenantID uuid.UUID, query string, limit, offset int) (*devicepairing.DeviceListPage, error) {
	var page devicepairing.DeviceListPage
	err := s.db.WithAdminTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		devices, total, err := devicepairing.ListDevices(ctx, tx, query, limit, offset)
		if err != nil {
			return err
		}
		page.Devices = devices
		page.Total = total
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &page, nil
}

// RevokeTenantDevice is devicepairing.Service.RevokeDevice's platform-admin
// counterpart — same effect (status REVOKED, every refresh token
// invalidated) but attributed to a platform admin rather than a tenant
// user, since there is no tenant actorUserID to record here.
func (s *Service) RevokeTenantDevice(ctx context.Context, tenantID, deviceID, platformAdminID uuid.UUID, reason string) error {
	return s.db.WithAdminTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		device, err := devicepairing.GetDeviceByID(ctx, tx, deviceID)
		if err != nil {
			return err
		}
		if err := devicepairing.SetDeviceStatus(ctx, tx, deviceID, "REVOKED"); err != nil {
			return err
		}
		if err := devicepairing.RevokeAllSessionsForDevice(ctx, tx, deviceID); err != nil {
			return err
		}
		return InsertCrossTenantAuditLog(ctx, tx, tenantID, platformAdminID, "DEVICE_REVOKED", "device", &deviceID, reason,
			map[string]interface{}{"display_name": device.DisplayName, "previous_status": device.Status})
	})
}

// GeneratePairingCodeForTenant is devicepairing.Service.GeneratePairingCode's
// platform-admin counterpart — the explicit, named gap this phase closes:
// tenants repeatedly forget to generate their own pairing code, and this
// session's workaround until now was hand-inserting a row via SQL directly
// against production. Runs under WithAdminTx (not WithAdminTenantTx) since
// this is a genuinely cross-tenant write with no prior tenant session to
// scope to — the insert supplies tenantID as a column value, which
// device_pairing_codes' admin_cross_tenant RLS policy permits unconditionally
// under admin_mode.
func (s *Service) GeneratePairingCodeForTenant(ctx context.Context, tenantID, platformAdminID uuid.UUID) (*devicepairing.GenerateResult, error) {
	code, err := devicepairing.GenerateCode()
	if err != nil {
		return nil, err
	}
	expiresAt := time.Now().Add(devicepairing.CodeTTL)

	err = s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		if _, err := devicepairing.InsertCodeByPlatformAdmin(ctx, tx, tenantID, platformAdminID, code, expiresAt); err != nil {
			return fmt.Errorf("insert pairing code: %w", err)
		}
		return InsertCrossTenantAuditLog(ctx, tx, tenantID, platformAdminID, "DEVICE_PAIRING_CODE_GENERATED_BY_PLATFORM_ADMIN", "device_pairing_code", nil, "",
			map[string]interface{}{"expires_at": expiresAt})
	})
	if err != nil {
		return nil, err
	}
	return &devicepairing.GenerateResult{Code: code, ExpiresAt: expiresAt}, nil
}

// indianFinancialYear returns the Apr 1–Mar 31 financial year containing t,
// matching this app's tenants.timezone default of Asia/Kolkata and every
// existing tenant's actual bookkeeping convention.
func indianFinancialYear(t time.Time) (start, end time.Time, label string) {
	year := t.Year()
	if t.Month() < time.April {
		year--
	}
	start = time.Date(year, time.April, 1, 0, 0, 0, 0, time.UTC)
	end = time.Date(year+1, time.March, 31, 23, 59, 59, 0, time.UTC)
	label = fmt.Sprintf("FY%d-%d", year, (year+1)%100)
	return start, end, label
}

func (s *Service) ListAuditLogsAllTenants(ctx context.Context, limit, offset int) ([]AuditLogEntry, error) {
	var out []AuditLogEntry
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = ListAuditLogsAllTenants(ctx, tx, limit, offset)
		return err
	})
	return out, err
}

func (s *Service) ListErrorLogs(ctx context.Context, limit, offset int) ([]ErrorLogEntry, error) {
	var out []ErrorLogEntry
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = ListErrorLogs(ctx, tx, limit, offset)
		return err
	})
	return out, err
}

func (s *Service) GetPlatformSettings(ctx context.Context) (*PlatformSettings, error) {
	var out *PlatformSettings
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = GetPlatformSettings(ctx, tx)
		return err
	})
	return out, err
}

func (s *Service) UpdatePlatformSettings(ctx context.Context, appName, appTagline string, logoURL, primaryColor *string) error {
	if appName == "" {
		return fmt.Errorf("%w: app_name is required", ErrValidation)
	}
	return s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		return UpdatePlatformSettings(ctx, tx, appName, appTagline, logoURL, primaryColor)
	})
}

// EffectiveBranding is what the app actually shows: a tenant's own override
// for any field they've set, falling back field-by-field to the platform
// default — the single source of truth replacing every hardcoded "FeedMate"
// / "Andipatti Animal Feed System" string that used to live in the Flutter
// source directly.
type EffectiveBranding struct {
	AppName      string
	AppTagline   string
	LogoURL      *string
	PrimaryColor *string
}

// ResolveBranding is deliberately reachable with no authentication at all —
// the login screen, by definition, has no access token yet. deviceUUID is
// optional: nil (or an unrecognized/inactive device) just returns the
// platform default, which is exactly the same "safe, always-available
// fallback" role a hardcoded string used to play, except this one is real
// data instead of a compile-time literal.
func (s *Service) ResolveBranding(ctx context.Context, deviceUUID *uuid.UUID) (*EffectiveBranding, error) {
	var out *EffectiveBranding
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		defaults, err := GetPlatformSettings(ctx, tx)
		if err != nil {
			return err
		}
		out = &EffectiveBranding{AppName: defaults.AppName, AppTagline: defaults.AppTagline, LogoURL: defaults.LogoURL, PrimaryColor: defaults.PrimaryColor}

		if deviceUUID == nil {
			return nil
		}
		device, err := identity.ResolveDeviceByUUID(ctx, tx, *deviceUUID)
		if err != nil {
			if errors.Is(err, identity.ErrNotFound) {
				return nil
			}
			return err
		}
		override, err := GetTenantBrandingOverride(ctx, tx, device.TenantID)
		if err != nil {
			if errors.Is(err, ErrNotFound) {
				return nil
			}
			return err
		}
		if override.AppDisplayName != nil && *override.AppDisplayName != "" {
			out.AppName = *override.AppDisplayName
		}
		if override.LogoURL != nil && *override.LogoURL != "" {
			out.LogoURL = override.LogoURL
		}
		if override.PrimaryColor != nil && *override.PrimaryColor != "" {
			out.PrimaryColor = override.PrimaryColor
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// RecordError persists one CodeInternal response's detail (see
// httpapi.SetErrorSink) using a short-lived, independent context — this must
// never block or fail the request that triggered it, so main.go wires it
// through a small wrapper that swallows errors after logging them.
func (s *Service) RecordError(ctx context.Context, requestID *uuid.UUID, statusCode int, message string) error {
	return s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		return InsertErrorLog(ctx, tx, requestID, statusCode, message)
	})
}
