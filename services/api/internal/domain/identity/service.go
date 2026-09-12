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
	ErrInvalidCredentials = errors.New("invalid credentials")
	ErrAccountLocked      = errors.New("account locked")
	ErrDeviceNotActive    = errors.New("device not registered or not active")
	ErrRefreshTokenInvalid = errors.New("refresh token invalid or expired")
)

type Service struct {
	db          *dbctx.DB
	signingKey  string
	accessTTL   time.Duration
	refreshTTL  time.Duration
	bcryptCost  int
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

		if err := RevokeSession(ctx, tx, session.ID); err != nil {
			return err
		}

		permissions, err := GetUserPermissions(ctx, tx, userID)
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
