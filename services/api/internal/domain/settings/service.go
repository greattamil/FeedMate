// Package settings exposes the Store Settings screen every shop owner
// needs before going live: legal/trade name, GSTIN, FSSAI license, contact
// details, address, invoice number prefix, and receipt header/footer text.
// Before this package existed, none of this was editable from the app —
// onboarding a real tenant required a raw SQL UPDATE against tenants.
package settings

import (
	"context"
	"errors"
	"fmt"
	"regexp"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
)

var ErrValidation = errors.New("validation error")

var logoDataURIPattern = regexp.MustCompile(`^data:image/(png|jpe?g|webp);base64,[A-Za-z0-9+/]+=*$`)

const maxLogoDataURILen = 1_500_000

type Service struct {
	db *dbctx.DB
}

func NewService(db *dbctx.DB) *Service {
	return &Service{db: db}
}

func (s *Service) GetStoreProfile(ctx context.Context, tenantID uuid.UUID) (StoreProfile, error) {
	var p StoreProfile
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		p, err = GetStoreProfile(ctx, tx, tenantID)
		return err
	})
	return p, err
}

// UpdateStoreProfile validates and persists the whole profile in one
// transaction, recording a before/after audit entry the same way every
// other tenant-admin-gated mutation in this system does.
func (s *Service) UpdateStoreProfile(ctx context.Context, tenantID, userID uuid.UUID, p StoreProfile) error {
	if p.LegalName == "" {
		return fmt.Errorf("%w: legal_name is required", ErrValidation)
	}
	if p.AddressLine1 == "" {
		return fmt.Errorf("%w: address_line1 is required", ErrValidation)
	}
	if p.City == "" {
		return fmt.Errorf("%w: city is required", ErrValidation)
	}
	if p.StateCode == "" {
		return fmt.Errorf("%w: state_code is required", ErrValidation)
	}
	if p.InvoicePrefix == "" {
		return fmt.Errorf("%w: invoice_prefix is required", ErrValidation)
	}
	if p.LogoDataURI != nil {
		if !logoDataURIPattern.MatchString(*p.LogoDataURI) {
			return fmt.Errorf("%w: logo must be a PNG, JPEG, or WEBP image", ErrValidation)
		}
		// ~1.5MB of base64 (~1.1MB decoded) is plenty for a print-quality
		// logo and keeps the row comfortably inside a single jsonb TOAST
		// chunk — reject anything larger client-side by refusing to persist it.
		if len(*p.LogoDataURI) > maxLogoDataURILen {
			return fmt.Errorf("%w: logo image is too large (max 1.5MB)", ErrValidation)
		}
	}

	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		before, err := GetStoreProfile(ctx, tx, tenantID)
		if err != nil {
			return fmt.Errorf("load current profile: %w", err)
		}
		if err := UpdateTenantProfile(ctx, tx, tenantID, p); err != nil {
			return fmt.Errorf("update tenant profile: %w", err)
		}
		if err := UpdateReceiptText(ctx, tx, tenantID, p.ReceiptHeader, p.ReceiptFooter, p.LogoDataURI); err != nil {
			return fmt.Errorf("update receipt text: %w", err)
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO audit_logs (tenant_id, actor_user_id, action_code, entity_type, entity_id, before_json, after_json)
			VALUES ($1,$2,'TENANT_SETTINGS_UPDATED','tenant',$1,$3,$4)
		`, tenantID, userID, profileToAuditJSON(before), profileToAuditJSON(p))
		return err
	})
}

func profileToAuditJSON(p StoreProfile) map[string]interface{} {
	return map[string]interface{}{
		"legal_name":       p.LegalName,
		"trade_name":       p.TradeName,
		"gstin":            p.GSTIN,
		"fssai_license_no": p.FSSAILicenseNo,
		"phone":            p.Phone,
		"email":            p.Email,
		"address_line1":    p.AddressLine1,
		"address_line2":    p.AddressLine2,
		"city":             p.City,
		"district":         p.District,
		"state_code":       p.StateCode,
		"postal_code":      p.PostalCode,
		"invoice_prefix":   p.InvoicePrefix,
		"receipt_header":   p.ReceiptHeader,
		"receipt_footer":   p.ReceiptFooter,
		// The image data itself is deliberately left out of the audit
		// trail — only whether a logo is present, to keep audit_logs rows
		// small and avoid duplicating megabytes of image bytes on every
		// settings edit.
		"logo_present": p.LogoDataURI != nil,
	}
}
