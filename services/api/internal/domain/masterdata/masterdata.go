// Package masterdata wraps the small, mostly-static lookup tables a product
// master-data form needs (categories, brands, UOMs, tax profiles). UOMs
// stay list-only here — a largely-fixed global seed (see ListUOMs).
// Categories, brands, and tax profiles all get full create/edit/deactivate
// support: tax profiles are the shop owner's central control over GST
// treatment per product, most notably PriceInclusive (whether a product's
// selling price already has GST baked in) — see TaxProfile's doc comment.
package masterdata

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
)

var (
	ErrValidation = errors.New("validation error")
	ErrNotFound   = errors.New("not found")
)

type Service struct {
	db *dbctx.DB
}

func NewService(db *dbctx.DB) *Service {
	return &Service{db: db}
}

type Category struct {
	ID        uuid.UUID
	Name      string
	LocalName string
	Active    bool
}

type Brand struct {
	ID        uuid.UUID
	Name      string
	LocalName string
	Active    bool
}

type UOM struct {
	ID   uuid.UUID
	Code string
	Name string
}

// TaxProfile is the shop owner's central, per-product-assignable control
// over GST treatment: every product picks one, and PriceInclusive on the
// chosen profile decides whether that product's selling_price already has
// GST baked in (pos.priceLine backs the taxable value out of the gross
// price) or GST is added on top of it at billing (the historical, still
// default behavior). Two products at the same 18% rate can therefore be
// priced completely differently — one "MRP inclusive", one "plus GST" —
// by simply pointing them at two different profiles, with no per-product
// schema change needed. Active status is a soft flag, never a hard
// delete, since historical products/invoices may reference a profile by
// id long after it stops being offered for new products.
type TaxProfile struct {
	ID             uuid.UUID
	Code           string
	Description    string
	SupplyType     string
	CGSTRate       decimal.Decimal
	SGSTRate       decimal.Decimal
	IGSTRate       decimal.Decimal
	CessRate       decimal.Decimal
	PriceInclusive bool
	Active         bool
}

// validSupplyTypes mirrors the tax_profiles.supply_type CHECK constraint
// (db/migrations/0003_product_uom_tax_pricing.up.sql) — kept in sync by
// hand since Postgres enforces the authoritative list and this is only a
// pre-flight check to turn a constraint violation into a clean 400.
var validSupplyTypes = map[string]bool{
	"INTRA_STATE": true,
	"INTER_STATE": true,
	"EXPORT":      true,
	"EXEMPT":      true,
	"NON_GST":     true,
}

func (s *Service) ListCategories(ctx context.Context, tenantID uuid.UUID) ([]Category, error) {
	var out []Category
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT id, name FROM categories WHERE active ORDER BY name`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var c Category
			if err := rows.Scan(&c.ID, &c.Name); err != nil {
				return err
			}
			out = append(out, c)
		}
		return rows.Err()
	})
	return out, err
}

// CreateCategory adds a new product category. Never a hard delete anywhere
// in this package — SetCategoryActive flips the `active` flag instead,
// since historical products may already reference a category by id.
func (s *Service) CreateCategory(ctx context.Context, tenantID uuid.UUID, name, localName string) (*Category, error) {
	if name == "" {
		return nil, fmt.Errorf("%w: name is required", ErrValidation)
	}
	var c Category
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		var localNamePtr *string
		if localName != "" {
			localNamePtr = &localName
		}
		return tx.QueryRow(ctx, `
			INSERT INTO categories (tenant_id, name, local_name) VALUES ($1,$2,$3)
			RETURNING id, name
		`, tenantID, name, localNamePtr).Scan(&c.ID, &c.Name)
	})
	if err != nil {
		return nil, err
	}
	return &c, nil
}

// ListAllCategories includes inactive categories too, for the dedicated
// management screen — a shop owner needs to see (and potentially
// reactivate) everything ever created, not just what's currently
// assignable to a product.
func (s *Service) ListAllCategories(ctx context.Context, tenantID uuid.UUID) ([]Category, error) {
	var out []Category
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT id, name, COALESCE(local_name, ''), active FROM categories ORDER BY name`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var c Category
			if err := rows.Scan(&c.ID, &c.Name, &c.LocalName, &c.Active); err != nil {
				return err
			}
			out = append(out, c)
		}
		return rows.Err()
	})
	return out, err
}

// UpdateCategory renames a category (and/or its local-language name) in
// place — the one edit operation that was previously missing, forcing a
// shop owner to deactivate-and-recreate just to fix a typo.
func (s *Service) UpdateCategory(ctx context.Context, tenantID, id uuid.UUID, name, localName string) error {
	if name == "" {
		return fmt.Errorf("%w: name is required", ErrValidation)
	}
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		var localNamePtr *string
		if localName != "" {
			localNamePtr = &localName
		}
		tag, err := tx.Exec(ctx, `UPDATE categories SET name = $2, local_name = $3, updated_at = now() WHERE id = $1`, id, name, localNamePtr)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}

// SetCategoryActive activates or deactivates a category — never a hard
// delete, since historical products may reference it by id.
func (s *Service) SetCategoryActive(ctx context.Context, tenantID, id uuid.UUID, active bool) error {
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE categories SET active = $2, updated_at = now() WHERE id = $1`, id, active)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}

func (s *Service) ListBrands(ctx context.Context, tenantID uuid.UUID) ([]Brand, error) {
	var out []Brand
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT id, name FROM brands WHERE active ORDER BY name`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var b Brand
			if err := rows.Scan(&b.ID, &b.Name); err != nil {
				return err
			}
			out = append(out, b)
		}
		return rows.Err()
	})
	return out, err
}

// CreateBrand adds a new product brand (see CreateCategory's doc comment —
// same never-hard-delete convention via SetBrandActive).
func (s *Service) CreateBrand(ctx context.Context, tenantID uuid.UUID, name, localName string) (*Brand, error) {
	if name == "" {
		return nil, fmt.Errorf("%w: name is required", ErrValidation)
	}
	var b Brand
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		var localNamePtr *string
		if localName != "" {
			localNamePtr = &localName
		}
		return tx.QueryRow(ctx, `
			INSERT INTO brands (tenant_id, name, local_name) VALUES ($1,$2,$3)
			RETURNING id, name
		`, tenantID, name, localNamePtr).Scan(&b.ID, &b.Name)
	})
	if err != nil {
		return nil, err
	}
	return &b, nil
}

// ListAllBrands includes inactive brands too — see ListAllCategories's doc
// comment for why.
func (s *Service) ListAllBrands(ctx context.Context, tenantID uuid.UUID) ([]Brand, error) {
	var out []Brand
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT id, name, COALESCE(local_name, ''), active FROM brands ORDER BY name`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var b Brand
			if err := rows.Scan(&b.ID, &b.Name, &b.LocalName, &b.Active); err != nil {
				return err
			}
			out = append(out, b)
		}
		return rows.Err()
	})
	return out, err
}

// UpdateBrand renames a brand in place — see UpdateCategory's doc comment.
func (s *Service) UpdateBrand(ctx context.Context, tenantID, id uuid.UUID, name, localName string) error {
	if name == "" {
		return fmt.Errorf("%w: name is required", ErrValidation)
	}
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		var localNamePtr *string
		if localName != "" {
			localNamePtr = &localName
		}
		tag, err := tx.Exec(ctx, `UPDATE brands SET name = $2, local_name = $3, updated_at = now() WHERE id = $1`, id, name, localNamePtr)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}

func (s *Service) SetBrandActive(ctx context.Context, tenantID, id uuid.UUID, active bool) error {
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE brands SET active = $2, updated_at = now() WHERE id = $1`, id, active)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}

// ListUOMs includes tenant-specific UOMs plus the global (tenant_id IS NULL)
// seeded set every tenant shares, matching how uoms.id is actually
// referenced from products (see migrations' global UOM seed rows).
func (s *Service) ListUOMs(ctx context.Context, tenantID uuid.UUID) ([]UOM, error) {
	var out []UOM
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id, code, name FROM uoms
			WHERE active AND (tenant_id = $1 OR tenant_id IS NULL)
			ORDER BY name
		`, tenantID)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var u UOM
			if err := rows.Scan(&u.ID, &u.Code, &u.Name); err != nil {
				return err
			}
			out = append(out, u)
		}
		return rows.Err()
	})
	return out, err
}

// ListTaxProfiles returns only active, currently-effective profiles — the
// set a product create/edit form should offer to pick from.
func (s *Service) ListTaxProfiles(ctx context.Context, tenantID uuid.UUID) ([]TaxProfile, error) {
	return s.listTaxProfiles(ctx, tenantID, false)
}

// ListAllTaxProfiles additionally includes inactive/not-yet-effective
// profiles, for the dedicated tax-profile management screen where a shop
// owner needs to see (and potentially reactivate) everything that's ever
// been configured, not just what's currently assignable to a product.
func (s *Service) ListAllTaxProfiles(ctx context.Context, tenantID uuid.UUID) ([]TaxProfile, error) {
	return s.listTaxProfiles(ctx, tenantID, true)
}

func (s *Service) listTaxProfiles(ctx context.Context, tenantID uuid.UUID, includeInactive bool) ([]TaxProfile, error) {
	var out []TaxProfile
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		query := `
			SELECT id, code, description, supply_type, cgst_rate, sgst_rate, igst_rate, cess_rate, price_inclusive, active
			FROM tax_profiles
		`
		if !includeInactive {
			query += ` WHERE active AND effective_from <= CURRENT_DATE AND (effective_to IS NULL OR effective_to > CURRENT_DATE)`
		}
		query += ` ORDER BY code`
		rows, err := tx.Query(ctx, query)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var t TaxProfile
			if err := rows.Scan(&t.ID, &t.Code, &t.Description, &t.SupplyType, &t.CGSTRate, &t.SGSTRate, &t.IGSTRate, &t.CessRate, &t.PriceInclusive, &t.Active); err != nil {
				return err
			}
			out = append(out, t)
		}
		return rows.Err()
	})
	return out, err
}

func validateTaxProfileInput(description, supplyType string, cgst, sgst, igst, cess decimal.Decimal) error {
	if description == "" {
		return fmt.Errorf("%w: description is required", ErrValidation)
	}
	if !validSupplyTypes[supplyType] {
		return fmt.Errorf("%w: supply_type must be one of INTRA_STATE, INTER_STATE, EXPORT, EXEMPT, NON_GST", ErrValidation)
	}
	for _, rate := range []decimal.Decimal{cgst, sgst, igst, cess} {
		if rate.LessThan(decimal.Zero) {
			return fmt.Errorf("%w: tax rates cannot be negative", ErrValidation)
		}
	}
	return nil
}

// CreateTaxProfile adds a new tax profile — the unit a shop owner creates
// once per distinct GST treatment they need (e.g. "GST18-EXCL" and
// "GST18-INCL" both at 18%, differing only in PriceInclusive) and then
// assigns to products from the product form's existing tax-profile picker.
func (s *Service) CreateTaxProfile(ctx context.Context, tenantID uuid.UUID, code, description, supplyType string, cgst, sgst, igst, cess decimal.Decimal, priceInclusive bool) (*TaxProfile, error) {
	if code == "" {
		return nil, fmt.Errorf("%w: code is required", ErrValidation)
	}
	if err := validateTaxProfileInput(description, supplyType, cgst, sgst, igst, cess); err != nil {
		return nil, err
	}
	t := TaxProfile{
		Code: code, Description: description, SupplyType: supplyType,
		CGSTRate: cgst, SGSTRate: sgst, IGSTRate: igst, CessRate: cess,
		PriceInclusive: priceInclusive, Active: true,
	}
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `
			INSERT INTO tax_profiles (tenant_id, code, description, supply_type, cgst_rate, sgst_rate, igst_rate, cess_rate, price_inclusive)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
			RETURNING id
		`, tenantID, code, description, supplyType, cgst, sgst, igst, cess, priceInclusive).Scan(&t.ID)
	})
	if err != nil {
		return nil, err
	}
	return &t, nil
}

// UpdateTaxProfile edits an existing profile's description, rates, and
// PriceInclusive flag in place (never its code, matching this project's
// convention of keeping an assigned identifier immutable once other rows
// may reference it). This does not retroactively touch past invoices —
// TaxProfile is snapshotted onto each invoice line at finalization time
// (see pos.TaxProfile's doc comment), so an edit here only changes pricing
// for sales made from this point forward.
func (s *Service) UpdateTaxProfile(ctx context.Context, tenantID, id uuid.UUID, description, supplyType string, cgst, sgst, igst, cess decimal.Decimal, priceInclusive bool) error {
	if err := validateTaxProfileInput(description, supplyType, cgst, sgst, igst, cess); err != nil {
		return err
	}
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			UPDATE tax_profiles
			SET description = $2, supply_type = $3, cgst_rate = $4, sgst_rate = $5, igst_rate = $6, cess_rate = $7,
			    price_inclusive = $8, updated_at = now()
			WHERE id = $1
		`, id, description, supplyType, cgst, sgst, igst, cess, priceInclusive)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}

// SetTaxProfileActive activates or deactivates a tax profile — never a
// hard delete, since existing products/invoices may reference it by id.
func (s *Service) SetTaxProfileActive(ctx context.Context, tenantID, id uuid.UUID, active bool) error {
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE tax_profiles SET active = $2, updated_at = now() WHERE id = $1`, id, active)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}
