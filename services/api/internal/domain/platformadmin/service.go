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
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/auth"
	"github.com/andipatti/feedmate/services/api/internal/dbctx"
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
