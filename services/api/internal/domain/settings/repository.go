package settings

import (
	"context"
	"encoding/json"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// StoreProfile is the shop profile a store owner sees and edits on the
// Store Settings screen: identity/compliance fields that live on tenants,
// plus free-form receipt header/footer text that has no dedicated column
// and lives in tenant_settings.extra_settings instead.
type StoreProfile struct {
	LegalName      string
	TradeName      *string
	GSTIN          *string
	FSSAILicenseNo *string
	Phone          *string
	Email          *string
	AddressLine1   string
	AddressLine2   *string
	City           string
	District       *string
	StateCode      string
	PostalCode     *string
	InvoicePrefix  string
	ReceiptHeader  *string
	ReceiptFooter  *string
	// LogoDataURI is the shop's uploaded logo, encoded as a data: URI
	// (e.g. "data:image/png;base64,...") — stored inline rather than as a
	// hosted URL since this deployment has no object storage, and printed
	// on both the invoice PDF and the on-screen invoice detail header.
	LogoDataURI *string
}

func GetStoreProfile(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID) (StoreProfile, error) {
	var p StoreProfile
	err := tx.QueryRow(ctx, `
		SELECT legal_name, trade_name, gstin, fssai_license_no, phone, email,
		       address_line1, address_line2, city, district, state_code, postal_code, invoice_prefix
		FROM tenants WHERE id = $1
	`, tenantID).Scan(
		&p.LegalName, &p.TradeName, &p.GSTIN, &p.FSSAILicenseNo, &p.Phone, &p.Email,
		&p.AddressLine1, &p.AddressLine2, &p.City, &p.District, &p.StateCode, &p.PostalCode, &p.InvoicePrefix,
	)
	if err != nil {
		return StoreProfile{}, err
	}

	var extra []byte
	if err := tx.QueryRow(ctx, `SELECT extra_settings FROM tenant_settings WHERE tenant_id = $1`, tenantID).Scan(&extra); err != nil {
		return StoreProfile{}, err
	}
	var parsed struct {
		ReceiptHeader *string `json:"receipt_header"`
		ReceiptFooter *string `json:"receipt_footer"`
		LogoDataURI   *string `json:"logo_data_uri"`
	}
	if len(extra) > 0 {
		if err := json.Unmarshal(extra, &parsed); err != nil {
			return StoreProfile{}, err
		}
	}
	p.ReceiptHeader = parsed.ReceiptHeader
	p.ReceiptFooter = parsed.ReceiptFooter
	p.LogoDataURI = parsed.LogoDataURI
	return p, nil
}

func UpdateTenantProfile(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, p StoreProfile) error {
	_, err := tx.Exec(ctx, `
		UPDATE tenants SET
			legal_name = $2, trade_name = $3, gstin = $4, fssai_license_no = $5,
			phone = $6, email = $7, address_line1 = $8, address_line2 = $9,
			city = $10, district = $11, state_code = $12, postal_code = $13,
			invoice_prefix = $14, updated_at = now()
		WHERE id = $1
	`, tenantID, p.LegalName, p.TradeName, p.GSTIN, p.FSSAILicenseNo,
		p.Phone, p.Email, p.AddressLine1, p.AddressLine2,
		p.City, p.District, p.StateCode, p.PostalCode, p.InvoicePrefix)
	return err
}

// UpdateReceiptText merges receipt_header/receipt_footer/logo_data_uri into
// tenant_settings.extra_settings, preserving whatever other keys that jsonb
// blob might already carry.
func UpdateReceiptText(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, header, footer, logoDataURI *string) error {
	extra := map[string]interface{}{}
	var current []byte
	if err := tx.QueryRow(ctx, `SELECT extra_settings FROM tenant_settings WHERE tenant_id = $1`, tenantID).Scan(&current); err != nil {
		return err
	}
	if len(current) > 0 {
		if err := json.Unmarshal(current, &extra); err != nil {
			return err
		}
	}
	if header != nil {
		extra["receipt_header"] = *header
	} else {
		delete(extra, "receipt_header")
	}
	if footer != nil {
		extra["receipt_footer"] = *footer
	} else {
		delete(extra, "receipt_footer")
	}
	if logoDataURI != nil {
		extra["logo_data_uri"] = *logoDataURI
	} else {
		delete(extra, "logo_data_uri")
	}
	encoded, err := json.Marshal(extra)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `UPDATE tenant_settings SET extra_settings = $2, updated_at = now() WHERE tenant_id = $1`, tenantID, encoded)
	return err
}
