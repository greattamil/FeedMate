package devicepairing

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

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
)

var (
	ErrValidation  = errors.New("validation error")
	ErrCodeInvalid = errors.New("pairing code is invalid, expired, or already used")
)

const (
	codeTTL     = 10 * time.Minute
	codeLength  = 8
	// Excludes visually ambiguous characters (0/O, 1/I/L) since a human reads
	// this code aloud or copies it between two physical devices.
	codeAlphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
)

type Service struct {
	db *dbctx.DB
}

func NewService(db *dbctx.DB) *Service {
	return &Service{db: db}
}

func generateCode() (string, error) {
	var b strings.Builder
	for i := 0; i < codeLength; i++ {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(codeAlphabet))))
		if err != nil {
			return "", fmt.Errorf("generate random code: %w", err)
		}
		b.WriteByte(codeAlphabet[n.Int64()])
	}
	return b.String(), nil
}

type GenerateResult struct {
	Code      string
	ExpiresAt time.Time
}

// GeneratePairingCode is called by an already-authenticated user holding
// device.manage. The resulting code is a short-lived, single-use bearer
// credential for exactly one new device registration to this tenant — it
// must be treated like a temporary password (shown once, not logged, not
// persisted client-side beyond the pairing screen).
func (s *Service) GeneratePairingCode(ctx context.Context, tenantID, userID uuid.UUID) (*GenerateResult, error) {
	code, err := generateCode()
	if err != nil {
		return nil, err
	}
	expiresAt := time.Now().Add(codeTTL)

	err = s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		_, err := InsertCode(ctx, tx, tenantID, userID, code, expiresAt)
		if err != nil {
			return fmt.Errorf("insert pairing code: %w", err)
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO audit_logs (tenant_id, actor_user_id, action_code, entity_type, after_json)
			VALUES ($1, $2, 'DEVICE_PAIRING_CODE_GENERATED', 'device_pairing_code', $3)
		`, tenantID, userID, map[string]interface{}{"expires_at": expiresAt})
		return err
	})
	if err != nil {
		return nil, err
	}
	return &GenerateResult{Code: code, ExpiresAt: expiresAt}, nil
}

type RegisterResult struct {
	TenantID uuid.UUID
}

// RegisterDevice is the sole unauthenticated entry point that lets a new
// device learn which tenant it belongs to via self-service (the alternative
// being an administrator directly inserting a devices row, as development
// fixtures do). It resolves the code under admin mode — the same
// narrowly-scoped cross-tenant lookup pattern used for login's device
// resolution — locks the row so a code cannot be redeemed twice
// concurrently, and creates the device under that tenant's own RLS context.
func (s *Service) RegisterDevice(ctx context.Context, code string, deviceUUID uuid.UUID, displayName, platform string) (*RegisterResult, error) {
	if code == "" {
		return nil, fmt.Errorf("%w: pairing code is required", ErrValidation)
	}
	code = strings.ToUpper(strings.TrimSpace(code))

	var tenantID uuid.UUID
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		pc, err := FindValidCodeForUpdate(ctx, tx, code)
		if err != nil {
			if errors.Is(err, ErrNotFound) {
				return ErrCodeInvalid
			}
			return err
		}
		if pc.UsedAt != nil || time.Now().After(pc.ExpiresAt) {
			return ErrCodeInvalid
		}
		tenantID = pc.TenantID

		deviceID, err := InsertDevice(ctx, tx, tenantID, deviceUUID, displayName, platform)
		if err != nil {
			return fmt.Errorf("register device: %w", err)
		}
		if err := MarkCodeUsed(ctx, tx, pc.ID, deviceID); err != nil {
			return fmt.Errorf("mark pairing code used: %w", err)
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO audit_logs (tenant_id, action_code, entity_type, entity_id, after_json)
			VALUES ($1, 'DEVICE_REGISTERED', 'device', $2, $3)
		`, tenantID, deviceID, map[string]interface{}{"device_uuid": deviceUUID, "display_name": displayName})
		return err
	})
	if err != nil {
		return nil, err
	}
	return &RegisterResult{TenantID: tenantID}, nil
}

// DeviceListPage is one page of the device-management browse list.
type DeviceListPage struct {
	Devices []Device
	Total   int
}

func (s *Service) ListDevices(ctx context.Context, tenantID uuid.UUID, query string, limit, offset int) (*DeviceListPage, error) {
	var page DeviceListPage
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		devices, total, err := ListDevices(ctx, tx, query, limit, offset)
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

// RevokeDevice locks a device out immediately: it flips the device's status
// to REVOKED (so it can never again complete a fresh login — see
// identity.Service.Login's status check) and, critically, also revokes
// every one of its still-valid refresh tokens (see
// RevokeAllSessionsForDevice's doc comment on why the status flag alone is
// not sufficient). This is the operation a shop owner uses when a device is
// lost or stolen.
func (s *Service) RevokeDevice(ctx context.Context, tenantID, deviceID, actorUserID uuid.UUID, reason string) error {
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		device, err := GetDeviceByID(ctx, tx, deviceID)
		if err != nil {
			return err
		}
		if err := SetDeviceStatus(ctx, tx, deviceID, "REVOKED"); err != nil {
			return err
		}
		if err := RevokeAllSessionsForDevice(ctx, tx, deviceID); err != nil {
			return err
		}
		auditPayload := map[string]interface{}{"display_name": device.DisplayName, "previous_status": device.Status}
		if reason != "" {
			auditPayload["reason"] = reason
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO audit_logs (tenant_id, actor_user_id, action_code, entity_type, entity_id, reason, after_json)
			VALUES ($1,$2,'DEVICE_REVOKED','device',$3,$4,$5)
		`, tenantID, actorUserID, deviceID, reason, auditPayload)
		return err
	})
}
