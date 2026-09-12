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
