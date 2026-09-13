package devicepairing

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var ErrNotFound = errors.New("pairing code not found")

func InsertCode(ctx context.Context, tx pgx.Tx, tenantID, createdByUserID uuid.UUID, code string, expiresAt time.Time) (uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO device_pairing_codes (tenant_id, code, created_by_user_id, expires_at)
		VALUES ($1, $2, $3, $4)
		RETURNING id
	`, tenantID, code, createdByUserID, expiresAt).Scan(&id)
	return id, err
}

type PairingCode struct {
	ID        uuid.UUID
	TenantID  uuid.UUID
	ExpiresAt time.Time
	UsedAt    *time.Time
}

// FindValidCodeForUpdate looks up an unused, unexpired pairing code by its
// value alone — the same "resolve tenant from an unauthenticated caller's
// one piece of evidence" pattern used for login's device resolution — and
// locks the row so two concurrent redemption attempts for the same code
// cannot both succeed. Must run under admin mode (see Service.RegisterDevice).
func FindValidCodeForUpdate(ctx context.Context, tx pgx.Tx, code string) (*PairingCode, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, tenant_id, expires_at, used_at
		FROM device_pairing_codes
		WHERE code = $1
		FOR UPDATE
	`, code)
	var pc PairingCode
	if err := row.Scan(&pc.ID, &pc.TenantID, &pc.ExpiresAt, &pc.UsedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &pc, nil
}

func MarkCodeUsed(ctx context.Context, tx pgx.Tx, codeID, deviceID uuid.UUID) error {
	_, err := tx.Exec(ctx, `
		UPDATE device_pairing_codes SET used_at = now(), used_by_device_id = $2 WHERE id = $1
	`, codeID, deviceID)
	return err
}

func InsertDevice(ctx context.Context, tx pgx.Tx, tenantID, deviceUUID uuid.UUID, displayName, platform string) (uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO devices (tenant_id, device_uuid, display_name, platform, status, registered_at)
		VALUES ($1, $2, $3, $4, 'ACTIVE', now())
		ON CONFLICT (tenant_id, device_uuid) DO UPDATE SET status = 'ACTIVE', display_name = EXCLUDED.display_name
		RETURNING id
	`, tenantID, deviceUUID, displayName, platform).Scan(&id)
	return id, err
}

var ErrDeviceNotFound = errors.New("device not found")

// Device is one registered device row, for the device-management screen.
type Device struct {
	ID            uuid.UUID
	DeviceUUID    uuid.UUID
	DisplayName   string
	Platform      string
	Status        string
	SecurityState string
	LastSeenAt    *time.Time
	RegisteredAt  time.Time
}

// ListDevices returns devices newest-registered-first, optionally filtered
// by a case-insensitive substring match on display name.
func ListDevices(ctx context.Context, tx pgx.Tx, query string, limit, offset int) ([]Device, int, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	var total int
	if err := tx.QueryRow(ctx, `
		SELECT COUNT(*) FROM devices WHERE $1 = '' OR display_name ILIKE '%' || $1 || '%'
	`, query).Scan(&total); err != nil {
		return nil, 0, err
	}

	rows, err := tx.Query(ctx, `
		SELECT id, device_uuid, display_name, platform, status, security_state, last_seen_at, registered_at
		FROM devices
		WHERE $1 = '' OR display_name ILIKE '%' || $1 || '%'
		ORDER BY registered_at DESC
		LIMIT $2 OFFSET $3
	`, query, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var out []Device
	for rows.Next() {
		var d Device
		if err := rows.Scan(&d.ID, &d.DeviceUUID, &d.DisplayName, &d.Platform, &d.Status, &d.SecurityState, &d.LastSeenAt, &d.RegisteredAt); err != nil {
			return nil, 0, err
		}
		out = append(out, d)
	}
	return out, total, rows.Err()
}

func GetDeviceByID(ctx context.Context, tx pgx.Tx, id uuid.UUID) (*Device, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, device_uuid, display_name, platform, status, security_state, last_seen_at, registered_at
		FROM devices WHERE id = $1
	`, id)
	var d Device
	if err := row.Scan(&d.ID, &d.DeviceUUID, &d.DisplayName, &d.Platform, &d.Status, &d.SecurityState, &d.LastSeenAt, &d.RegisteredAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrDeviceNotFound
		}
		return nil, err
	}
	return &d, nil
}

// SetDeviceStatus flips a device's status flag (e.g. to REVOKED) — never a
// hard delete, since device_sessions/sync_cursors/sync_transactions all
// reference it.
func SetDeviceStatus(ctx context.Context, tx pgx.Tx, id uuid.UUID, status string) error {
	var deactivatedAt *time.Time
	if status != "ACTIVE" {
		now := time.Now()
		deactivatedAt = &now
	}
	tag, err := tx.Exec(ctx, `UPDATE devices SET status = $2, deactivated_at = $3 WHERE id = $1`, id, status, deactivatedAt)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrDeviceNotFound
	}
	return nil
}

// RevokeAllSessionsForDevice invalidates every still-valid refresh token
// issued to this device. Flipping devices.status alone is not enough to cut
// off access: identity.Service.Refresh never checks device status, only
// whether the specific session is revoked/expired — so an already-issued,
// not-yet-expired refresh token would otherwise keep working after a
// device is marked REVOKED. This is the operation that actually locks a
// lost/stolen device out immediately.
func RevokeAllSessionsForDevice(ctx context.Context, tx pgx.Tx, deviceID uuid.UUID) error {
	_, err := tx.Exec(ctx, `UPDATE device_sessions SET revoked_at = now() WHERE device_id = $1 AND revoked_at IS NULL`, deviceID)
	return err
}
