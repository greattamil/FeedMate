package product

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

var ErrNotFound = errors.New("product not found")

// Product mirrors the products table. Money/weight/quantity fields use
// decimal.Decimal (backed by PostgreSQL NUMERIC via the registered codec) —
// never float32/float64 — per the mandatory numeric precision rules.
type Product struct {
	ID                   uuid.UUID
	SKU                  string
	Name                 string
	LocalNameTa          *string
	CategoryID           *uuid.UUID
	BrandID              *uuid.UUID
	DefaultSaleUOMID     uuid.UUID
	DefaultPurchaseUOMID uuid.UUID
	BaseInventoryUOMID   uuid.UUID
	HSNCode              *string
	TaxProfileID         *uuid.UUID
	PackSize             *decimal.Decimal
	StandardWeightKg     *decimal.Decimal
	MRP                  *decimal.Decimal
	SellingPrice         *decimal.Decimal
	ReorderLevel         *decimal.Decimal
	ReorderTarget        *decimal.Decimal
	MinPriceFloor        *decimal.Decimal
	BatchRequired        bool
	ExpiryRequired       bool
	LooseSaleAllowed     bool
	ScaleRequired        bool
	ProductType          string
	Active               bool
}

type Barcode struct {
	Barcode   string
	IsPrimary bool
}

type Alias struct {
	AliasText      string
	NormalizedText string
	LanguageCode   string
	AliasType      string
	Priority       int
}

func Create(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, p *Product) error {
	row := tx.QueryRow(ctx, `
		INSERT INTO products (
			tenant_id, sku, name, local_name_ta, category_id, brand_id,
			default_sale_uom_id, default_purchase_uom_id, base_inventory_uom_id,
			hsn_code, tax_profile_id, pack_size, standard_weight_kg, mrp, selling_price,
			reorder_level, reorder_target, min_price_floor,
			batch_required, expiry_required, loose_sale_allowed, scale_required, product_type
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23)
		RETURNING id, active
	`, tenantID, p.SKU, p.Name, p.LocalNameTa, p.CategoryID, p.BrandID,
		p.DefaultSaleUOMID, p.DefaultPurchaseUOMID, p.BaseInventoryUOMID,
		p.HSNCode, p.TaxProfileID, p.PackSize, p.StandardWeightKg, p.MRP, p.SellingPrice,
		p.ReorderLevel, p.ReorderTarget, p.MinPriceFloor,
		p.BatchRequired, p.ExpiryRequired, p.LooseSaleAllowed, p.ScaleRequired, p.ProductType,
	)
	// Scan back every server-defaulted column (not just id) so the in-memory
	// struct returned to the caller reflects the true persisted row rather
	// than Go zero-values for fields the INSERT didn't set explicitly.
	return row.Scan(&p.ID, &p.Active)
}

func GetByID(ctx context.Context, tx pgx.Tx, id uuid.UUID) (*Product, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, sku, name, local_name_ta, category_id, brand_id,
		       default_sale_uom_id, default_purchase_uom_id, base_inventory_uom_id,
		       hsn_code, tax_profile_id, pack_size, standard_weight_kg, mrp, selling_price,
		       reorder_level, reorder_target, min_price_floor,
		       batch_required, expiry_required, loose_sale_allowed, scale_required, product_type, active
		FROM products WHERE id = $1
	`, id)
	return scanProduct(row)
}

// Update persists every mutable field of an existing product. SKU is
// intentionally excluded — it is the immutable business key referenced by
// every historical invoice/batch/GRN line, and PRD master-data conventions
// treat it the same way customer/supplier codes are treated: fixed at
// creation.
func Update(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, p *Product) error {
	cmd, err := tx.Exec(ctx, `
		UPDATE products SET
			name = $3, local_name_ta = $4, category_id = $5, brand_id = $6,
			default_sale_uom_id = $7, default_purchase_uom_id = $8, base_inventory_uom_id = $9,
			hsn_code = $10, tax_profile_id = $11, pack_size = $12, standard_weight_kg = $13,
			mrp = $14, selling_price = $15, reorder_level = $16, reorder_target = $17,
			min_price_floor = $18, batch_required = $19, expiry_required = $20,
			loose_sale_allowed = $21, scale_required = $22, product_type = $23, updated_at = now()
		WHERE tenant_id = $1 AND id = $2
	`, tenantID, p.ID, p.Name, p.LocalNameTa, p.CategoryID, p.BrandID,
		p.DefaultSaleUOMID, p.DefaultPurchaseUOMID, p.BaseInventoryUOMID,
		p.HSNCode, p.TaxProfileID, p.PackSize, p.StandardWeightKg, p.MRP, p.SellingPrice,
		p.ReorderLevel, p.ReorderTarget, p.MinPriceFloor,
		p.BatchRequired, p.ExpiryRequired, p.LooseSaleAllowed, p.ScaleRequired, p.ProductType,
	)
	if err != nil {
		return err
	}
	if cmd.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// SetActive is the only supported way to remove a product from sale/receipt
// workflows — a real DELETE would violate every historical invoice/batch/GRN
// line's foreign key, and PRD master-data conventions never hard-delete a
// referenced master record (the same pattern used for customers/suppliers).
func SetActive(ctx context.Context, tx pgx.Tx, tenantID, productID uuid.UUID, active bool) error {
	cmd, err := tx.Exec(ctx, `UPDATE products SET active = $3, updated_at = now() WHERE tenant_id = $1 AND id = $2`,
		tenantID, productID, active)
	if err != nil {
		return err
	}
	if cmd.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ListOptions filters the master product list/browse screen (distinct from
// Search, which ranks fuzzy matches for point-of-sale lookup).
type ListOptions struct {
	Query      string // matched against name/SKU, substring, case-insensitive
	CategoryID *uuid.UUID
	ActiveOnly bool
	Limit      int
	Offset     int
}

func List(ctx context.Context, tx pgx.Tx, opts ListOptions) ([]Product, int, error) {
	limit := opts.Limit
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	conditions := []string{"1=1"}
	args := []interface{}{}
	argN := 1
	if opts.ActiveOnly {
		conditions = append(conditions, "active")
	}
	if opts.CategoryID != nil {
		conditions = append(conditions, fmt.Sprintf("category_id = $%d", argN))
		args = append(args, *opts.CategoryID)
		argN++
	}
	if opts.Query != "" {
		conditions = append(conditions, fmt.Sprintf("(name ILIKE $%d OR sku ILIKE $%d)", argN, argN))
		args = append(args, "%"+opts.Query+"%")
		argN++
	}
	where := strings.Join(conditions, " AND ")

	var total int
	countSQL := "SELECT count(*) FROM products WHERE " + where
	if err := tx.QueryRow(ctx, countSQL, args...).Scan(&total); err != nil {
		return nil, 0, err
	}

	listArgs := append(append([]interface{}{}, args...), limit, opts.Offset)
	listSQL := fmt.Sprintf(`
		SELECT id, sku, name, local_name_ta, category_id, brand_id,
		       default_sale_uom_id, default_purchase_uom_id, base_inventory_uom_id,
		       hsn_code, tax_profile_id, pack_size, standard_weight_kg, mrp, selling_price,
		       reorder_level, reorder_target, min_price_floor,
		       batch_required, expiry_required, loose_sale_allowed, scale_required, product_type, active
		FROM products WHERE %s ORDER BY name ASC LIMIT $%d OFFSET $%d
	`, where, argN, argN+1)
	rows, err := tx.Query(ctx, listSQL, listArgs...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var out []Product
	for rows.Next() {
		p, err := scanProductRow(rows)
		if err != nil {
			return nil, 0, err
		}
		out = append(out, *p)
	}
	return out, total, rows.Err()
}

func scanProductRow(rows pgx.Rows) (*Product, error) {
	var p Product
	err := rows.Scan(&p.ID, &p.SKU, &p.Name, &p.LocalNameTa, &p.CategoryID, &p.BrandID,
		&p.DefaultSaleUOMID, &p.DefaultPurchaseUOMID, &p.BaseInventoryUOMID,
		&p.HSNCode, &p.TaxProfileID, &p.PackSize, &p.StandardWeightKg, &p.MRP, &p.SellingPrice,
		&p.ReorderLevel, &p.ReorderTarget, &p.MinPriceFloor,
		&p.BatchRequired, &p.ExpiryRequired, &p.LooseSaleAllowed, &p.ScaleRequired, &p.ProductType, &p.Active)
	return &p, err
}

func GetByBarcode(ctx context.Context, tx pgx.Tx, barcode string) (*Product, error) {
	row := tx.QueryRow(ctx, `
		SELECT p.id, p.sku, p.name, p.local_name_ta, p.category_id, p.brand_id,
		       p.default_sale_uom_id, p.default_purchase_uom_id, p.base_inventory_uom_id,
		       p.hsn_code, p.tax_profile_id, p.pack_size, p.standard_weight_kg, p.mrp, p.selling_price,
		       p.reorder_level, p.reorder_target, p.min_price_floor,
		       p.batch_required, p.expiry_required, p.loose_sale_allowed, p.scale_required, p.product_type, p.active
		FROM products p
		JOIN product_barcodes b ON b.product_id = p.id
		WHERE b.barcode = $1 AND b.active AND p.active
		ORDER BY b.is_primary DESC
		LIMIT 1
	`, barcode)
	return scanProduct(row)
}

func scanProduct(row pgx.Row) (*Product, error) {
	var p Product
	err := row.Scan(&p.ID, &p.SKU, &p.Name, &p.LocalNameTa, &p.CategoryID, &p.BrandID,
		&p.DefaultSaleUOMID, &p.DefaultPurchaseUOMID, &p.BaseInventoryUOMID,
		&p.HSNCode, &p.TaxProfileID, &p.PackSize, &p.StandardWeightKg, &p.MRP, &p.SellingPrice,
		&p.ReorderLevel, &p.ReorderTarget, &p.MinPriceFloor,
		&p.BatchRequired, &p.ExpiryRequired, &p.LooseSaleAllowed, &p.ScaleRequired, &p.ProductType, &p.Active)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &p, nil
}

// SearchResult ranks matches per PRD A4: exact barcode/SKU > exact name >
// exact alias > normalized/fuzzy alias, in that order.
type SearchResult struct {
	Product     Product
	MatchType   string // BARCODE, SKU, NAME, ALIAS, FUZZY
	MatchedText string
}

// Search implements barcode/SKU/name/alias/fuzzy product lookup for POS and
// catalogue screens, per the ranking in PRD A4: exact barcode > exact SKU >
// exact name > exact alias > normalized/fuzzy. It never silently guesses
// among ambiguous fuzzy matches for a financial transaction — callers must
// present fuzzy results for explicit operator confirmation before use in a
// sale.
//
// rawQuery (trimmed but otherwise untouched) is used for barcode/SKU
// matching, since those are structured codes that legitimately contain
// hyphens and punctuation; normalizedQuery (Unicode/whitespace/punctuation
// normalized — see NormalizeAliasText) is used for name/alias/fuzzy
// matching, since colloquial and transliterated names must match regardless
// of spacing or punctuation differences. Conflating the two would either
// break exact SKU lookups (hyphens stripped) or weaken alias matching.
//
// categoryID narrows results to one category (e.g. the POS catalog's
// category filter chips, which are populated from the same categories
// table this filters against — see masterdata.ListCategories — rather
// than any client-side hard-coded list). A nil categoryID applies no
// filter. When normalizedQuery is empty, the ILIKE '%%' comparisons match
// every active product, so an empty query plus a categoryID browses that
// whole category, and an empty query with a nil categoryID browses the
// whole active catalog — both are legitimate ("show me the catalog", the
// default state of a POS screen before the cashier types or filters
// anything) and both stay bounded by limit regardless of catalog size.
func Search(ctx context.Context, tx pgx.Tx, rawQuery, normalizedQuery string, categoryID *uuid.UUID, limit int) ([]SearchResult, error) {
	if limit <= 0 || limit > 50 {
		limit = 20
	}
	rows, err := tx.Query(ctx, `
		WITH ranked AS (
			SELECT p.id, p.sku, p.name, p.local_name_ta, p.category_id, p.brand_id,
			       p.default_sale_uom_id, p.default_purchase_uom_id, p.base_inventory_uom_id,
			       p.hsn_code, p.tax_profile_id, p.pack_size, p.standard_weight_kg, p.mrp, p.selling_price,
			       p.reorder_level, p.reorder_target, p.min_price_floor,
			       p.batch_required, p.expiry_required, p.loose_sale_allowed, p.scale_required, p.product_type, p.active,
			       CASE
			           WHEN EXISTS (SELECT 1 FROM product_barcodes b WHERE b.product_id = p.id AND b.barcode = $1) THEN 1
			           WHEN p.sku ILIKE $1 THEN 2
			           WHEN p.name ILIKE $2 THEN 3
			           WHEN EXISTS (SELECT 1 FROM product_aliases a WHERE a.product_id = p.id AND a.normalized_text = $2) THEN 4
			           ELSE 5
			       END AS rank,
			       GREATEST(
			           similarity(p.name, $2),
			           COALESCE((SELECT MAX(similarity(a.normalized_text, $2)) FROM product_aliases a WHERE a.product_id = p.id), 0)
			       ) AS sim
			FROM products p
			WHERE p.active
			  AND (p.category_id = $4 OR $4::uuid IS NULL)
			  AND (
			      p.name ILIKE '%' || $2 || '%'
			      OR p.sku ILIKE '%' || $1 || '%'
			      OR EXISTS (SELECT 1 FROM product_barcodes b WHERE b.product_id = p.id AND b.barcode = $1)
			      OR EXISTS (SELECT 1 FROM product_aliases a WHERE a.product_id = p.id AND (a.normalized_text ILIKE '%' || $2 || '%' OR similarity(a.normalized_text, $2) > 0.3))
			      OR similarity(p.name, $2) > 0.3
			  )
		)
		SELECT id, sku, name, local_name_ta, category_id, brand_id,
		       default_sale_uom_id, default_purchase_uom_id, base_inventory_uom_id,
		       hsn_code, tax_profile_id, pack_size, standard_weight_kg, mrp, selling_price,
		       reorder_level, reorder_target, min_price_floor,
		       batch_required, expiry_required, loose_sale_allowed, scale_required, product_type, active, rank
		FROM ranked
		ORDER BY rank ASC, sim DESC, name ASC
		LIMIT $3
	`, rawQuery, normalizedQuery, limit, categoryID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var results []SearchResult
	for rows.Next() {
		var p Product
		var rank int
		if err := rows.Scan(&p.ID, &p.SKU, &p.Name, &p.LocalNameTa, &p.CategoryID, &p.BrandID,
			&p.DefaultSaleUOMID, &p.DefaultPurchaseUOMID, &p.BaseInventoryUOMID,
			&p.HSNCode, &p.TaxProfileID, &p.PackSize, &p.StandardWeightKg, &p.MRP, &p.SellingPrice,
			&p.ReorderLevel, &p.ReorderTarget, &p.MinPriceFloor,
			&p.BatchRequired, &p.ExpiryRequired, &p.LooseSaleAllowed, &p.ScaleRequired, &p.ProductType, &p.Active, &rank); err != nil {
			return nil, err
		}
		matchType := map[int]string{1: "BARCODE", 2: "SKU", 3: "NAME", 4: "ALIAS"}[rank]
		if matchType == "" {
			matchType = "FUZZY"
		}
		results = append(results, SearchResult{Product: p, MatchType: matchType})
	}
	return results, rows.Err()
}

func AddBarcode(ctx context.Context, tx pgx.Tx, tenantID, productID uuid.UUID, barcode string, isPrimary bool) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO product_barcodes (tenant_id, product_id, barcode, is_primary)
		VALUES ($1, $2, $3, $4)
	`, tenantID, productID, barcode, isPrimary)
	return err
}

func AddAlias(ctx context.Context, tx pgx.Tx, tenantID, productID uuid.UUID, a Alias) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO product_aliases (tenant_id, product_id, alias_text, normalized_text, language_code, alias_type, priority)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
	`, tenantID, productID, a.AliasText, a.NormalizedText, a.LanguageCode, a.AliasType, a.Priority)
	return err
}

func ListBarcodes(ctx context.Context, tx pgx.Tx, productID uuid.UUID) ([]Barcode, error) {
	rows, err := tx.Query(ctx, `
		SELECT barcode, is_primary FROM product_barcodes WHERE product_id = $1 AND active ORDER BY is_primary DESC, barcode
	`, productID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Barcode
	for rows.Next() {
		var b Barcode
		if err := rows.Scan(&b.Barcode, &b.IsPrimary); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

func ListAliases(ctx context.Context, tx pgx.Tx, productID uuid.UUID) ([]Alias, error) {
	rows, err := tx.Query(ctx, `
		SELECT alias_text, normalized_text, language_code, alias_type, priority
		FROM product_aliases WHERE product_id = $1 AND active ORDER BY priority, alias_text
	`, productID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Alias
	for rows.Next() {
		var a Alias
		if err := rows.Scan(&a.AliasText, &a.NormalizedText, &a.LanguageCode, &a.AliasType, &a.Priority); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// DeleteBarcodes and DeleteAliases hard-delete every row for a product so
// Update can replace the full set with whatever the edit form submitted
// (simpler and less error-prone than diffing individual rows for a small,
// infrequently-changed list). Neither table is referenced by any other
// table, so this carries no foreign-key/historical-integrity risk (unlike
// the product row itself, which is never hard-deleted — see SetActive).
func DeleteBarcodes(ctx context.Context, tx pgx.Tx, tenantID, productID uuid.UUID) error {
	_, err := tx.Exec(ctx, `DELETE FROM product_barcodes WHERE tenant_id = $1 AND product_id = $2`, tenantID, productID)
	return err
}

func DeleteAliases(ctx context.Context, tx pgx.Tx, tenantID, productID uuid.UUID) error {
	_, err := tx.Exec(ctx, `DELETE FROM product_aliases WHERE tenant_id = $1 AND product_id = $2`, tenantID, productID)
	return err
}
