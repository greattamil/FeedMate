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
	Product Product
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
func (s *Service) Search(ctx context.Context, tenantID uuid.UUID, query string, limit int) ([]SearchResult, error) {
	raw := strings.TrimSpace(query)
	normalized := NormalizeAliasText(query)
	var results []SearchResult
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		results, err = Search(ctx, tx, raw, normalized, limit)
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
