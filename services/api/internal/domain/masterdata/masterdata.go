// Package masterdata wraps the small, mostly-static lookup tables a product
// master-data form needs (categories, brands, UOMs, tax profiles). These are
// read-only from the API's perspective today — there is no create/edit UI
// for them yet, only for products that reference them — so this package
// intentionally only exposes List, not full CRUD.
package masterdata

import (
	"context"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
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
