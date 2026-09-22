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
	ID               uuid.UUID
	TenantID         uuid.UUID
	Username         string
	PasswordHash     string
	DisplayName      string
	Status           string
	FailedLoginCount int
	LockedUntil      *time.Time
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

var ErrUsernameTaken = errors.New("username is already taken")

// InsertUser creates a new staff account. tenant_id + username has no
// explicit UNIQUE constraint at the DB level beyond the global `username`
// column being looked up directly by Login (see FindUserByUsername), so
// callers must check for an existing username themselves before inserting
// — see Service.CreateUser.
func InsertUser(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, username, passwordHash, displayName, phone, email string) (uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO users (tenant_id, username, password_hash, display_name, phone, email, status)
		VALUES ($1,$2,$3,$4,$5,$6,'ACTIVE')
		RETURNING id
	`, tenantID, username, passwordHash, displayName, nullIfEmptyStr(phone), nullIfEmptyStr(email)).Scan(&id)
	return id, err
}

func nullIfEmptyStr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// UserSummary is one row of the staff list — no password hash, unlike the
// internal User struct Login/Refresh use.
type UserSummary struct {
	ID          uuid.UUID
	Username    string
	DisplayName string
	Phone       *string
	Email       *string
	Status      string
	LastLoginAt *time.Time
}

// ListUsers returns staff accounts newest-first, optionally filtered by a
// case-insensitive substring match on username or display name.
func ListUsers(ctx context.Context, tx pgx.Tx, query string, limit, offset int) ([]UserSummary, int, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	var total int
	if err := tx.QueryRow(ctx, `
		SELECT COUNT(*) FROM users WHERE $1 = '' OR username ILIKE '%' || $1 || '%' OR display_name ILIKE '%' || $1 || '%'
	`, query).Scan(&total); err != nil {
		return nil, 0, err
	}

	rows, err := tx.Query(ctx, `
		SELECT id, username, display_name, phone, email, status, last_login_at
		FROM users
		WHERE $1 = '' OR username ILIKE '%' || $1 || '%' OR display_name ILIKE '%' || $1 || '%'
		ORDER BY display_name
		LIMIT $2 OFFSET $3
	`, query, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var out []UserSummary
	for rows.Next() {
		var u UserSummary
		if err := rows.Scan(&u.ID, &u.Username, &u.DisplayName, &u.Phone, &u.Email, &u.Status, &u.LastLoginAt); err != nil {
			return nil, 0, err
		}
		out = append(out, u)
	}
	return out, total, rows.Err()
}

// GetUserSummaryByID is the read-only, no-password-hash counterpart to
// GetUserByID — used by the staff detail screen, which has no business
// touching the internal User struct Login/Refresh rely on.
func GetUserSummaryByID(ctx context.Context, tx pgx.Tx, userID uuid.UUID) (*UserSummary, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, username, display_name, phone, email, status, last_login_at
		FROM users WHERE id = $1
	`, userID)
	var u UserSummary
	if err := row.Scan(&u.ID, &u.Username, &u.DisplayName, &u.Phone, &u.Email, &u.Status, &u.LastLoginAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &u, nil
}

// SetUserStatus activates or deactivates a staff account — never a hard
// delete, since historical invoices/GRNs/audit entries reference the user
// as an actor. A deactivated user can never again log in (see Login's
// status check) but their history stays intact and attributable.
func SetUserStatus(ctx context.Context, tx pgx.Tx, id uuid.UUID, status string) error {
	tag, err := tx.Exec(ctx, `UPDATE users SET status = $2 WHERE id = $1`, id, status)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// UpdateUser changes a staff member's contact/profile fields — never their
// username (that's the login identifier other rows may reference by
// convention in reports) and never their password (see SetPasswordHash).
func UpdateUser(ctx context.Context, tx pgx.Tx, id uuid.UUID, displayName, phone, email string) error {
	tag, err := tx.Exec(ctx, `
		UPDATE users SET display_name = $2, phone = $3, email = $4 WHERE id = $1
	`, id, displayName, nullIfEmptyStr(phone), nullIfEmptyStr(email))
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// SetPasswordHash overwrites a staff account's password — used for an
// admin-initiated reset (this shop has no email/SMS flow for self-service
// reset, so a manager sets a new password directly and hands it to the
// staff member out of band).
func SetPasswordHash(ctx context.Context, tx pgx.Tx, id uuid.UUID, passwordHash string) error {
	tag, err := tx.Exec(ctx, `UPDATE users SET password_hash = $2, failed_login_count = 0, locked_until = NULL WHERE id = $1`, id, passwordHash)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// Role is one assignable role — either a system default (is_system_role,
// seeded once per tenant at provisioning) or a tenant-defined custom role.
type Role struct {
	ID           uuid.UUID
	Name         string
	Description  *string
	IsSystemRole bool
}

func ListRoles(ctx context.Context, tx pgx.Tx) ([]Role, error) {
	rows, err := tx.Query(ctx, `SELECT id, name, description, is_system_role FROM roles ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Role
	for rows.Next() {
		var r Role
		if err := rows.Scan(&r.ID, &r.Name, &r.Description, &r.IsSystemRole); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// ListRolesForUser returns the role ids currently assigned to a user.
func ListRolesForUser(ctx context.Context, tx pgx.Tx, userID uuid.UUID) ([]uuid.UUID, error) {
	rows, err := tx.Query(ctx, `SELECT role_id FROM user_roles WHERE user_id = $1`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []uuid.UUID
	for rows.Next() {
		var id uuid.UUID
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

func AssignRole(ctx context.Context, tx pgx.Tx, tenantID, userID, roleID uuid.UUID) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO user_roles (tenant_id, user_id, role_id) VALUES ($1,$2,$3)
		ON CONFLICT (user_id, role_id) DO NOTHING
	`, tenantID, userID, roleID)
	return err
}

func RevokeRole(ctx context.Context, tx pgx.Tx, userID, roleID uuid.UUID) error {
	_, err := tx.Exec(ctx, `DELETE FROM user_roles WHERE user_id = $1 AND role_id = $2`, userID, roleID)
	return err
}
