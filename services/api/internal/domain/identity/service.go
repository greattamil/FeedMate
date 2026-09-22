package identity

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/auth"
	"github.com/andipatti/feedmate/services/api/internal/dbctx"
)

const (
	maxFailedLoginAttempts = 5
	lockoutDuration        = 15 * time.Minute
)

var (
	ErrInvalidCredentials  = errors.New("invalid credentials")
	ErrAccountLocked       = errors.New("account locked")
	ErrDeviceNotActive     = errors.New("device not registered or not active")
	ErrRefreshTokenInvalid = errors.New("refresh token invalid or expired")
	// ErrTenantNotActive is returned when a platform admin has suspended or
	// closed the tenant — status was a schema field nothing actually
	// enforced before this (see 0021's doc comment), so a suspended client
	// could keep using the app indefinitely.
	ErrTenantNotActive = errors.New("tenant account is suspended")
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
	UserID       uuid.UUID
	TenantID     uuid.UUID
	DisplayName  string
	Permissions  []string
}

// Login resolves the device's tenant, verifies credentials scoped to that tenant,
// and issues a new access/refresh token pair. Device resolution is the one
// pre-authentication step that legitimately crosses tenant boundaries (see
// ResolveDeviceByUUID); everything after it runs under the resolved tenant's RLS
// context so a compromised or mistaken lookup cannot leak another tenant's data.
func (s *Service) Login(ctx context.Context, deviceUUID uuid.UUID, username, password string) (*LoginResult, error) {
	var device *Device
	if err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		d, err := ResolveDeviceByUUID(ctx, tx, deviceUUID)
		if err != nil {
			if errors.Is(err, ErrNotFound) {
				return ErrDeviceNotActive
			}
			return fmt.Errorf("resolve device: %w", err)
		}
		device = d
		status, err := GetTenantStatus(ctx, tx, d.TenantID)
		if err != nil {
			return fmt.Errorf("get tenant status: %w", err)
		}
		if status != "ACTIVE" {
			return ErrTenantNotActive
		}
		return nil
	}); err != nil {
		return nil, err
	}

	if device.Status != "ACTIVE" && device.Status != "PENDING" {
		return nil, ErrDeviceNotActive
	}

	var result *LoginResult
	err := s.db.WithTenantTx(ctx, device.TenantID, func(tx pgx.Tx) error {
		user, err := FindUserByUsername(ctx, tx, username)
		if err != nil {
			if errors.Is(err, ErrNotFound) {
				return ErrInvalidCredentials
			}
			return fmt.Errorf("find user: %w", err)
		}

		if user.LockedUntil != nil && user.LockedUntil.After(time.Now()) {
			return ErrAccountLocked
		}
		if user.Status != "ACTIVE" {
			return ErrInvalidCredentials
		}

		if !auth.VerifyPassword(user.PasswordHash, password) {
			_ = RecordLoginFailure(ctx, tx, user.ID, maxFailedLoginAttempts, lockoutDuration)
			return ErrInvalidCredentials
		}

		if err := RecordLoginSuccess(ctx, tx, user.ID); err != nil {
			return fmt.Errorf("record login success: %w", err)
		}

		permissions, err := GetUserPermissions(ctx, tx, user.ID)
		if err != nil {
			return fmt.Errorf("get permissions: %w", err)
		}

		refreshToken, err := auth.GenerateOpaqueToken()
		if err != nil {
			return fmt.Errorf("generate token: %w", err)
		}
		refreshHash := auth.HashRefreshToken(refreshToken)
		expiresAt := time.Now().Add(s.refreshTTL)
		if _, err := CreateSession(ctx, tx, device.TenantID, device.ID, user.ID, refreshHash, expiresAt); err != nil {
			return fmt.Errorf("create session: %w", err)
		}
		if err := TouchDeviceLastSeen(ctx, tx, device.ID); err != nil {
			return fmt.Errorf("touch device: %w", err)
		}

		accessToken, err := auth.IssueAccessToken(s.signingKey, user.ID, device.TenantID, device.ID, permissions, s.accessTTL)
		if err != nil {
			return err
		}

		result = &LoginResult{
			AccessToken:  accessToken,
			RefreshToken: refreshToken,
			ExpiresIn:    int64(s.accessTTL.Seconds()),
			UserID:       user.ID,
			TenantID:     device.TenantID,
			DisplayName:  user.DisplayName,
			Permissions:  permissions,
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return result, nil
}

// Refresh rotates a refresh token: the old one is revoked and a new pair is
// issued. This limits the blast radius of a leaked refresh token to one use.
func (s *Service) Refresh(ctx context.Context, tenantID uuid.UUID, refreshToken string) (*LoginResult, error) {
	refreshHash := auth.HashRefreshToken(refreshToken)
	var result *LoginResult
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		session, userID, deviceID, err := FindActiveSessionByHash(ctx, tx, refreshHash)
		if err != nil {
			if errors.Is(err, ErrNotFound) {
				return ErrRefreshTokenInvalid
			}
			return err
		}

		// A tenant suspended after this session was issued must not be able
		// to keep it alive indefinitely by only ever refreshing.
		status, err := GetTenantStatus(ctx, tx, tenantID)
		if err != nil {
			return fmt.Errorf("get tenant status: %w", err)
		}
		if status != "ACTIVE" {
			return ErrTenantNotActive
		}

		if err := RevokeSession(ctx, tx, session.ID); err != nil {
			return err
		}

		permissions, err := GetUserPermissions(ctx, tx, userID)
		if err != nil {
			return err
		}

		// A refreshed session must carry the same display name/permissions a
		// fresh login would — otherwise a client that only ever calls
		// Refresh (e.g. to restore a session after an app restart, never
		// re-prompting for a password) silently loses both, even though the
		// user's role hasn't changed.
		user, err := GetUserByID(ctx, tx, userID)
		if err != nil {
			return err
		}

		newRefreshToken, err := auth.GenerateOpaqueToken()
		if err != nil {
			return err
		}
		newHash := auth.HashRefreshToken(newRefreshToken)
		expiresAt := time.Now().Add(s.refreshTTL)
		if _, err := CreateSession(ctx, tx, tenantID, deviceID, userID, newHash, expiresAt); err != nil {
			return err
		}

		accessToken, err := auth.IssueAccessToken(s.signingKey, userID, tenantID, deviceID, permissions, s.accessTTL)
		if err != nil {
			return err
		}

		result = &LoginResult{
			AccessToken:  accessToken,
			RefreshToken: newRefreshToken,
			ExpiresIn:    int64(s.accessTTL.Seconds()),
			UserID:       userID,
			TenantID:     tenantID,
			DisplayName:  user.DisplayName,
			Permissions:  permissions,
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return result, nil
}

func (s *Service) Logout(ctx context.Context, tenantID uuid.UUID, refreshToken string) error {
	refreshHash := auth.HashRefreshToken(refreshToken)
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		return RevokeSessionByHash(ctx, tx, refreshHash)
	})
}

var ErrValidation = errors.New("validation error")

type CreateUserInput struct {
	Username    string
	Password    string
	DisplayName string
	Phone       string
	Email       string
	RoleIDs     []uuid.UUID
}

// CreateUser registers a new staff account and assigns it zero or more
// roles in the same transaction. Usernames are checked for availability
// tenant-scoped here, then relied on to actually collide at the DB level
// if two concurrent creates race (there is no unique index on username
// alone across tenants, matching how Login already looks it up).
func (s *Service) CreateUser(ctx context.Context, tenantID uuid.UUID, in CreateUserInput) (uuid.UUID, error) {
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
	err = s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		if _, err := FindUserByUsername(ctx, tx, in.Username); err == nil {
			return ErrUsernameTaken
		} else if !errors.Is(err, ErrNotFound) {
			return err
		}
		id, err := InsertUser(ctx, tx, tenantID, in.Username, hash, in.DisplayName, in.Phone, in.Email)
		if err != nil {
			return fmt.Errorf("insert user: %w", err)
		}
		for _, roleID := range in.RoleIDs {
			if err := AssignRole(ctx, tx, tenantID, id, roleID); err != nil {
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

type UserListPage struct {
	Users []UserSummary
	Total int
}

func (s *Service) ListUsers(ctx context.Context, tenantID uuid.UUID, query string, limit, offset int) (*UserListPage, error) {
	var page UserListPage
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		users, total, err := ListUsers(ctx, tx, query, limit, offset)
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

// UserDetail is a staff member's full profile plus their currently
// assigned role ids, for the staff detail/edit screen.
type UserDetail struct {
	User    UserSummary
	RoleIDs []uuid.UUID
}

func (s *Service) GetUserDetail(ctx context.Context, tenantID, userID uuid.UUID) (*UserDetail, error) {
	var detail UserDetail
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		user, err := GetUserSummaryByID(ctx, tx, userID)
		if err != nil {
			return err
		}
		detail.User = *user
		roleIDs, err := ListRolesForUser(ctx, tx, userID)
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

// SetUserStatus activates or deactivates a staff account — never a hard
// delete (see repository.SetUserStatus's doc comment). A shop owner cannot
// deactivate their own account through this path by omission — callers
// (the HTTP handler) are expected to reject self-deactivation explicitly,
// since nothing here has enough context to know "self" from any other user.
func (s *Service) SetUserStatus(ctx context.Context, tenantID, userID uuid.UUID, active bool) error {
	status := "ACTIVE"
	if !active {
		status = "DISABLED"
	}
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		return SetUserStatus(ctx, tx, userID, status)
	})
}

type UpdateUserInput struct {
	DisplayName string
	Phone       string
	Email       string
}

// UpdateUser changes a staff member's profile fields — display name, phone,
// email. Username and password are never touched here (see SetPassword).
func (s *Service) UpdateUser(ctx context.Context, tenantID, userID uuid.UUID, in UpdateUserInput) error {
	if in.DisplayName == "" {
		return fmt.Errorf("%w: display_name is required", ErrValidation)
	}
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		return UpdateUser(ctx, tx, userID, in.DisplayName, in.Phone, in.Email)
	})
}

// SetPassword overwrites a staff account's password (admin-initiated
// reset — see repository.SetPasswordHash's doc comment). Same minimum
// length rule as CreateUser.
func (s *Service) SetPassword(ctx context.Context, tenantID, userID uuid.UUID, newPassword string) error {
	if len(newPassword) < 8 {
		return fmt.Errorf("%w: password must be at least 8 characters", ErrValidation)
	}
	hash, err := auth.HashPassword(newPassword, s.bcryptCost)
	if err != nil {
		return fmt.Errorf("hash password: %w", err)
	}
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		return SetPasswordHash(ctx, tx, userID, hash)
	})
}

func (s *Service) ListRoles(ctx context.Context, tenantID uuid.UUID) ([]Role, error) {
	var roles []Role
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		roles, err = ListRoles(ctx, tx)
		return err
	})
	return roles, err
}

// SetUserRoles replaces a user's full set of role assignments with exactly
// the given list — the same full-replace convention used for a product's
// barcodes/aliases (see product.Service.Update), simpler for a form to
// reason about than issuing incremental grant/revoke calls.
func (s *Service) SetUserRoles(ctx context.Context, tenantID, userID uuid.UUID, roleIDs []uuid.UUID) error {
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		if _, err := GetUserByID(ctx, tx, userID); err != nil {
			return err
		}
		existing, err := ListRolesForUser(ctx, tx, userID)
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
				if err := RevokeRole(ctx, tx, userID, id); err != nil {
					return err
				}
			}
		}
		for _, id := range roleIDs {
			if !current[id] {
				if err := AssignRole(ctx, tx, tenantID, userID, id); err != nil {
					return err
				}
			}
		}
		return nil
	})
}
