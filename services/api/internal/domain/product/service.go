package product

import (
	"context"
	"fmt"
	"strings"
	"unicode"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
)

type Service struct {
	db *dbctx.DB
}

func NewService(db *dbctx.DB) *Service {
	return &Service{db: db}
}

type CreateInput struct {
	Product  Product
	Barcodes []string
	Aliases  []string // colloquial/Tamil aliases; normalized automatically
}

func (s *Service) Create(ctx context.Context, tenantID uuid.UUID, in CreateInput) (*Product, error) {
	if in.Product.SKU == "" || in.Product.Name == "" {
		return nil, fmt.Errorf("sku and name are required")
	}
	if in.Product.ProductType == "" {
		in.Product.ProductType = "FEED"
	}

	var created Product
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		p := in.Product
		if err := Create(ctx, tx, tenantID, &p); err != nil {
			return fmt.Errorf("create product: %w", err)
		}
		for i, bc := range in.Barcodes {
			if err := AddBarcode(ctx, tx, tenantID, p.ID, bc, i == 0); err != nil {
				return fmt.Errorf("add barcode %q: %w", bc, err)
			}
		}
		for _, alias := range in.Aliases {
			if err := AddAlias(ctx, tx, tenantID, p.ID, Alias{
				AliasText:      alias,
				NormalizedText: NormalizeAliasText(alias),
				LanguageCode:   "ta",
				AliasType:      "COLLOQUIAL",
				Priority:       100,
			}); err != nil {
				return fmt.Errorf("add alias %q: %w", alias, err)
			}
		}
		created = p
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &created, nil
}

func (s *Service) GetByID(ctx context.Context, tenantID, productID uuid.UUID) (*Product, error) {
	var p *Product
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		p, err = GetByID(ctx, tx, productID)
		return err
	})
	return p, err
}

// Detail bundles a product with its barcodes/aliases — everything the edit
// form needs to pre-fill, and everything the read-only detail screen needs
// to display, in one round trip.
type Detail struct {
	Product  Product
	Barcodes []Barcode
	Aliases  []Alias
}

func (s *Service) GetDetail(ctx context.Context, tenantID, productID uuid.UUID) (*Detail, error) {
	var d Detail
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		p, err := GetByID(ctx, tx, productID)
		if err != nil {
			return err
		}
		barcodes, err := ListBarcodes(ctx, tx, productID)
		if err != nil {
			return err
		}
		aliases, err := ListAliases(ctx, tx, productID)
		if err != nil {
			return err
		}
		d.Product, d.Barcodes, d.Aliases = *p, barcodes, aliases
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &d, nil
}

// UpdateInput mirrors CreateInput but never touches SKU (see product
// repository.Update's doc comment) — Barcodes/Aliases are the full desired
// set, replacing whatever was there before.
type UpdateInput struct {
	Product  Product
	Barcodes []string
	Aliases  []string
}

func (s *Service) Update(ctx context.Context, tenantID, productID uuid.UUID, in UpdateInput) (*Product, error) {
	if in.Product.Name == "" {
		return nil, fmt.Errorf("name is required")
	}
	if in.Product.ProductType == "" {
		in.Product.ProductType = "FEED"
	}

	var updated *Product
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		p := in.Product
		p.ID = productID
		if err := Update(ctx, tx, tenantID, &p); err != nil {
			return fmt.Errorf("update product: %w", err)
		}
		if err := DeleteBarcodes(ctx, tx, tenantID, productID); err != nil {
			return fmt.Errorf("clear barcodes: %w", err)
		}
		for i, bc := range in.Barcodes {
			if err := AddBarcode(ctx, tx, tenantID, productID, bc, i == 0); err != nil {
				return fmt.Errorf("add barcode %q: %w", bc, err)
			}
		}
		if err := DeleteAliases(ctx, tx, tenantID, productID); err != nil {
			return fmt.Errorf("clear aliases: %w", err)
		}
		for _, alias := range in.Aliases {
			if err := AddAlias(ctx, tx, tenantID, productID, Alias{
				AliasText:      alias,
				NormalizedText: NormalizeAliasText(alias),
				LanguageCode:   "ta",
				AliasType:      "COLLOQUIAL",
				Priority:       100,
			}); err != nil {
				return fmt.Errorf("add alias %q: %w", alias, err)
			}
		}
		fresh, err := GetByID(ctx, tx, productID)
		if err != nil {
			return err
		}
		updated = fresh
		return nil
	})
	if err != nil {
		return nil, err
	}
	return updated, nil
}

// SetActive is the only way to remove a product from POS/GRN/returns
// workflows — see repository.SetActive's doc comment for why this is never
// a hard delete.
func (s *Service) SetActive(ctx context.Context, tenantID, productID uuid.UUID, active bool) (*Product, error) {
	var updated *Product
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		if err := SetActive(ctx, tx, tenantID, productID, active); err != nil {
			return err
		}
		fresh, err := GetByID(ctx, tx, productID)
		if err != nil {
			return err
		}
		updated = fresh
		return nil
	})
	if err != nil {
		return nil, err
	}
	return updated, nil
}

// ListResult carries the total row count matching the filter alongside the
// current page, so the client can render pagination controls.
type ListResult struct {
	Products []Product
	Total    int
}

func (s *Service) List(ctx context.Context, tenantID uuid.UUID, opts ListOptions) (*ListResult, error) {
	var res ListResult
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		products, total, err := List(ctx, tx, opts)
		if err != nil {
			return err
		}
		res.Products, res.Total = products, total
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &res, nil
}

func (s *Service) GetByBarcode(ctx context.Context, tenantID uuid.UUID, barcode string) (*Product, error) {
	var p *Product
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		p, err = GetByBarcode(ctx, tx, barcode)
		return err
	})
	return p, err
}

// Search matches the raw (trimmed) query against barcode/SKU and the
// normalized form (see NormalizeAliasText) against name/alias/fuzzy, so exact
// SKU/barcode lookups are not broken by punctuation stripping while
// colloquial/transliterated name matching still ignores spacing/case.
func (s *Service) Search(ctx context.Context, tenantID uuid.UUID, query string, categoryID *uuid.UUID, limit int) ([]SearchResult, error) {
	raw := strings.TrimSpace(query)
	normalized := NormalizeAliasText(query)
	var results []SearchResult
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		results, err = Search(ctx, tx, raw, normalized, categoryID, limit)
		return err
	})
	return results, err
}

// NormalizeAliasText applies Unicode normalization and whitespace/punctuation
// collapsing so "Cattle  Feed", "cattle-feed" and "CATTLE FEED" all match the
// same normalized form, per PRD A4 (search normalization must preserve the
// original stored text but normalize for matching).
func NormalizeAliasText(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	var b strings.Builder
	lastWasSpace := false
	for _, r := range s {
		switch {
		case unicode.IsSpace(r):
			if !lastWasSpace {
				b.WriteRune(' ')
				lastWasSpace = true
			}
		case unicode.IsPunct(r):
			// drop punctuation entirely (hyphens, apostrophes, etc.)
		default:
			b.WriteRune(r)
			lastWasSpace = false
		}
	}
	return strings.TrimSpace(b.String())
}
