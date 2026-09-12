package identity

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var ErrNotFound = errors.New("not found")

type Device struct {
	ID       uuid.UUID
	TenantID uuid.UUID
	Status   string
}

type User struct {
	ID                uuid.UUID
	TenantID          uuid.UUID
	Username          string
	PasswordHash      string
	DisplayName       string
	Status            string
	FailedLoginCount  int
	LockedUntil       *time.Time
}

// ResolveDeviceByUUID looks up which tenant a device belongs to. This is the one
// legitimate pre-authentication cross-tenant lookup (a device physically cannot
// know its own tenant_id before this call) and must run under admin mode, scoped
// to exactly this narrow read — callers must not reuse the admin transaction for
// anything else.
func ResolveDeviceByUUID(ctx context.Context, tx pgx.Tx, deviceUUID uuid.UUID) (*Device, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, tenant_id, status FROM devices WHERE device_uuid = $1
	`, deviceUUID)
	var d Device
	if err := row.Scan(&d.ID, &d.TenantID, &d.Status); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &d, nil
}

func FindUserByUsername(ctx context.Context, tx pgx.Tx, username string) (*User, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, tenant_id, username, password_hash, display_name, status,
		       failed_login_count, locked_until
		FROM users WHERE username = $1
	`, username)
	var u User
	if err := row.Scan(&u.ID, &u.TenantID, &u.Username, &u.PasswordHash, &u.DisplayName,
		&u.Status, &u.FailedLoginCount, &u.LockedUntil); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &u, nil
}

// GetUserByID looks up a user by id — used by Refresh, which only has the
// user id encoded in the (now-revoked) refresh session, not the username
// Login authenticated with.
func GetUserByID(ctx context.Context, tx pgx.Tx, userID uuid.UUID) (*User, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, tenant_id, username, password_hash, display_name, status,
		       failed_login_count, locked_until
		FROM users WHERE id = $1
	`, userID)
	var u User
	if err := row.Scan(&u.ID, &u.TenantID, &u.Username, &u.PasswordHash, &u.DisplayName,
		&u.Status, &u.FailedLoginCount, &u.LockedUntil); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &u, nil
}

func RecordLoginSuccess(ctx context.Context, tx pgx.Tx, userID uuid.UUID) error {
	_, err := tx.Exec(ctx, `
		UPDATE users SET last_login_at = now(), failed_login_count = 0, locked_until = NULL
		WHERE id = $1
	`, userID)
	return err
}

// RecordLoginFailure increments the failed-login counter and applies a lockout
// once the threshold is reached, mitigating brute-force credential attacks.
func RecordLoginFailure(ctx context.Context, tx pgx.Tx, userID uuid.UUID, maxAttempts int, lockoutDuration time.Duration) error {
	_, err := tx.Exec(ctx, `
		UPDATE users
		SET failed_login_count = failed_login_count + 1,
		    locked_until = CASE
		        WHEN failed_login_count + 1 >= $2 THEN now() + $3::interval
		        ELSE locked_until
		    END
		WHERE id = $1
	`, userID, maxAttempts, lockoutDuration.String())
	return err
}

func GetUserPermissions(ctx context.Context, tx pgx.Tx, userID uuid.UUID) ([]string, error) {
	rows, err := tx.Query(ctx, `
		SELECT DISTINCT p.code
		FROM user_roles ur
		JOIN role_permissions rp ON rp.role_id = ur.role_id
		JOIN permissions p ON p.id = rp.permission_id
		WHERE ur.user_id = $1
	`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var perms []string
	for rows.Next() {
		var code string
		if err := rows.Scan(&code); err != nil {
			return nil, err
		}
		perms = append(perms, code)
	}
	return perms, rows.Err()
}

type Session struct {
	ID               uuid.UUID
	RefreshTokenHash string
	ExpiresAt        time.Time
}

func CreateSession(ctx context.Context, tx pgx.Tx, tenantID, deviceID, userID uuid.UUID, refreshTokenHash string, expiresAt time.Time) (uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO device_sessions (tenant_id, device_id, user_id, refresh_token_hash, expires_at)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id
	`, tenantID, deviceID, userID, refreshTokenHash, expiresAt).Scan(&id)
	return id, err
}

func FindActiveSessionByHash(ctx context.Context, tx pgx.Tx, refreshTokenHash string) (*Session, uuid.UUID, uuid.UUID, error) {
	var s Session
	var userID, deviceID uuid.UUID
	row := tx.QueryRow(ctx, `
		SELECT id, refresh_token_hash, expires_at, user_id, device_id
		FROM device_sessions
		WHERE refresh_token_hash = $1 AND revoked_at IS NULL AND expires_at > now()
	`, refreshTokenHash)
	if err := row.Scan(&s.ID, &s.RefreshTokenHash, &s.ExpiresAt, &userID, &deviceID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, uuid.Nil, uuid.Nil, ErrNotFound
		}
		return nil, uuid.Nil, uuid.Nil, err
	}
	return &s, userID, deviceID, nil
}

func RevokeSession(ctx context.Context, tx pgx.Tx, sessionID uuid.UUID) error {
	_, err := tx.Exec(ctx, `UPDATE device_sessions SET revoked_at = now() WHERE id = $1`, sessionID)
	return err
}

func RevokeSessionByHash(ctx context.Context, tx pgx.Tx, refreshTokenHash string) error {
	_, err := tx.Exec(ctx, `UPDATE device_sessions SET revoked_at = now() WHERE refresh_token_hash = $1`, refreshTokenHash)
	return err
}

func TouchDeviceLastSeen(ctx context.Context, tx pgx.Tx, deviceID uuid.UUID) error {
	_, err := tx.Exec(ctx, `UPDATE devices SET last_seen_at = now() WHERE id = $1`, deviceID)
	return err
}
