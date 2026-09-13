// Package masterdata wraps the small, mostly-static lookup tables a product
// master-data form needs (categories, brands, UOMs, tax profiles). UOMs and
// tax profiles stay list-only here — UOMs are a largely-fixed global seed
// (see ListUOMs) and tax profiles carry GST-compliance implications (rate
// history, HSN mapping) that deserve a dedicated flow, not a quick add
// button. Categories and brands, by contrast, are the two lookups a shop
// owner routinely needs to extend as they onboard new product lines, so
// those two get full create/deactivate support.
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
	ID   uuid.UUID
	Name string
}

type Brand struct {
	ID   uuid.UUID
	Name string
}

type UOM struct {
	ID   uuid.UUID
	Code string
	Name string
}

// TaxProfile is trimmed to what a product form needs to display and pick
// from — the effective-dated rate history detail lives entirely server-side
// in pos.CalculateLineTax, never re-derived by a client.
type TaxProfile struct {
	ID          uuid.UUID
	Code        string
	Description string
	CGSTRate    decimal.Decimal
	SGSTRate    decimal.Decimal
	IGSTRate    decimal.Decimal
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

func (s *Service) ListTaxProfiles(ctx context.Context, tenantID uuid.UUID) ([]TaxProfile, error) {
	var out []TaxProfile
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id, code, description, cgst_rate, sgst_rate, igst_rate
			FROM tax_profiles
			WHERE active AND effective_from <= CURRENT_DATE AND (effective_to IS NULL OR effective_to > CURRENT_DATE)
			ORDER BY code
		`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var t TaxProfile
			if err := rows.Scan(&t.ID, &t.Code, &t.Description, &t.CGSTRate, &t.SGSTRate, &t.IGSTRate); err != nil {
				return err
			}
			out = append(out, t)
		}
		return rows.Err()
	})
	return out, err
}
