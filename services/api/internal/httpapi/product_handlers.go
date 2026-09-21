package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/auth"
	"github.com/andipatti/feedmate/services/api/internal/domain/product"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type ProductHandlers struct {
	Product *product.Service
}

// claimsFromRequest reads the trusted claims the auth middleware already
// verified and stored via reqctx.WithClaims (the shared package that avoids
// an import cycle between httpapi and middleware).
func claimsFromRequest(r *http.Request) (*auth.AccessClaims, bool) {
	return reqctx.Claims(r.Context())
}

// productRequest is shared by Create and Update. SKU is only read by Create
// — Update never lets the SKU change (see product.repository.Update's doc
// comment), so productRequest.SKU is simply ignored when decoding a PUT body.
type productRequest struct {
	SKU                  string   `json:"sku"`
	Name                 string   `json:"name"`
	LocalNameTa          string   `json:"local_name_ta,omitempty"`
	CategoryID           string   `json:"category_id,omitempty"`
	BrandID              string   `json:"brand_id,omitempty"`
	DefaultSaleUOMID     string   `json:"default_sale_uom_id"`
	DefaultPurchaseUOMID string   `json:"default_purchase_uom_id"`
	BaseInventoryUOMID   string   `json:"base_inventory_uom_id"`
	HSNCode              string   `json:"hsn_code,omitempty"`
	TaxProfileID         string   `json:"tax_profile_id,omitempty"`
	PackSize             string   `json:"pack_size,omitempty"`
	StandardWeightKg     string   `json:"standard_weight_kg,omitempty"`
	MRP                  string   `json:"mrp,omitempty"`
	SellingPrice         string   `json:"selling_price,omitempty"`
	ReorderLevel         string   `json:"reorder_level,omitempty"`
	ReorderTarget        string   `json:"reorder_target,omitempty"`
	MinPriceFloor        string   `json:"min_price_floor,omitempty"`
	BatchRequired        bool     `json:"batch_required"`
	ExpiryRequired       bool     `json:"expiry_required"`
	LooseSaleAllowed     bool     `json:"loose_sale_allowed"`
	ScaleRequired        bool     `json:"scale_required"`
	ProductType          string   `json:"product_type,omitempty"`
	// A pointer, unlike the other booleans above: a plain bool can't tell
	// "the caller explicitly turned alerts off" apart from "the caller
	// doesn't know this field exists yet" (e.g. an older client build), and
	// those two cases must not be treated the same — the column defaults to
	// true precisely so a client that's silent on this never flips a
	// product's alerts off by omission. nil means "use the default".
	StockAlertEnabled *bool    `json:"stock_alert_enabled,omitempty"`
	Barcodes          []string `json:"barcodes,omitempty"`
	Aliases           []string `json:"aliases,omitempty"`
}

// toProduct converts the wire request into a product.Product, validating
// every UUID/decimal field. On error it writes the response itself and
// returns ok=false, so callers can just `if !ok { return }`.
func (req *productRequest) toProduct(w http.ResponseWriter, reqID string) (product.Product, bool) {
	var p product.Product
	saleUOM, err1 := uuid.Parse(req.DefaultSaleUOMID)
	purchaseUOM, err2 := uuid.Parse(req.DefaultPurchaseUOMID)
	baseUOM, err3 := uuid.Parse(req.BaseInventoryUOMID)
	if err1 != nil || err2 != nil || err3 != nil {
		WriteError(w, reqID, CodeValidation, "default_sale_uom_id, default_purchase_uom_id, base_inventory_uom_id must be valid UUIDs")
		return p, false
	}
	p.Name = req.Name
	p.DefaultSaleUOMID, p.DefaultPurchaseUOMID, p.BaseInventoryUOMID = saleUOM, purchaseUOM, baseUOM
	p.BatchRequired, p.ExpiryRequired = req.BatchRequired, req.ExpiryRequired
	p.LooseSaleAllowed, p.ScaleRequired = req.LooseSaleAllowed, req.ScaleRequired
	p.ProductType = req.ProductType
	p.StockAlertEnabled = req.StockAlertEnabled == nil || *req.StockAlertEnabled

	if req.LocalNameTa != "" {
		p.LocalNameTa = &req.LocalNameTa
	}
	if req.HSNCode != "" {
		p.HSNCode = &req.HSNCode
	}
	if req.CategoryID != "" {
		id, err := uuid.Parse(req.CategoryID)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "category_id must be a valid UUID")
			return p, false
		}
		p.CategoryID = &id
	}
	if req.BrandID != "" {
		id, err := uuid.Parse(req.BrandID)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "brand_id must be a valid UUID")
			return p, false
		}
		p.BrandID = &id
	}
	if req.TaxProfileID != "" {
		id, err := uuid.Parse(req.TaxProfileID)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "tax_profile_id must be a valid UUID")
			return p, false
		}
		p.TaxProfileID = &id
	}

	decimalFields := []struct {
		raw    string
		field  **decimal.Decimal
		errMsg string
	}{
		{req.PackSize, &p.PackSize, "pack_size must be a valid decimal"},
		{req.StandardWeightKg, &p.StandardWeightKg, "standard_weight_kg must be a valid decimal"},
		{req.MRP, &p.MRP, "mrp must be a valid decimal amount"},
		{req.SellingPrice, &p.SellingPrice, "selling_price must be a valid decimal amount"},
		{req.ReorderLevel, &p.ReorderLevel, "reorder_level must be a valid decimal"},
		{req.ReorderTarget, &p.ReorderTarget, "reorder_target must be a valid decimal"},
		{req.MinPriceFloor, &p.MinPriceFloor, "min_price_floor must be a valid decimal amount"},
	}
	for _, f := range decimalFields {
		d, err := parseOptionalDecimal(f.raw)
		if err != nil {
			WriteError(w, reqID, CodeValidation, f.errMsg)
			return p, false
		}
		*f.field = d
	}
	return p, true
}

type productResponse struct {
	ID                   string `json:"id"`
	SKU                  string `json:"sku"`
	Name                 string `json:"name"`
	LocalNameTa          string `json:"local_name_ta,omitempty"`
	CategoryID           string `json:"category_id,omitempty"`
	BrandID              string `json:"brand_id,omitempty"`
	DefaultSaleUOMID     string `json:"default_sale_uom_id"`
	DefaultPurchaseUOMID string `json:"default_purchase_uom_id"`
	BaseInventoryUOMID   string `json:"base_inventory_uom_id"`
	HSNCode              string `json:"hsn_code,omitempty"`
	TaxProfileID         string `json:"tax_profile_id,omitempty"`
	PackSize             string `json:"pack_size,omitempty"`
	StandardWeightKg     string `json:"standard_weight_kg,omitempty"`
	MRP                  string `json:"mrp,omitempty"`
	SellingPrice         string `json:"selling_price,omitempty"`
	ReorderLevel         string `json:"reorder_level,omitempty"`
	ReorderTarget        string `json:"reorder_target,omitempty"`
	MinPriceFloor        string `json:"min_price_floor,omitempty"`
	BatchRequired        bool   `json:"batch_required"`
	ExpiryRequired       bool   `json:"expiry_required"`
	LooseSaleAllowed     bool   `json:"loose_sale_allowed"`
	ScaleRequired        bool   `json:"scale_required"`
	ProductType          string `json:"product_type"`
	Active               bool   `json:"active"`
	StockAlertEnabled    bool   `json:"stock_alert_enabled"`
}

func toProductResponse(p *product.Product) productResponse {
	resp := productResponse{
		ID:                   p.ID.String(),
		SKU:                  p.SKU,
		Name:                 p.Name,
		DefaultSaleUOMID:     p.DefaultSaleUOMID.String(),
		DefaultPurchaseUOMID: p.DefaultPurchaseUOMID.String(),
		BaseInventoryUOMID:   p.BaseInventoryUOMID.String(),
		BatchRequired:        p.BatchRequired,
		ExpiryRequired:       p.ExpiryRequired,
		LooseSaleAllowed:     p.LooseSaleAllowed,
		ScaleRequired:        p.ScaleRequired,
		ProductType:          p.ProductType,
		Active:               p.Active,
		StockAlertEnabled:    p.StockAlertEnabled,
	}
	if p.LocalNameTa != nil {
		resp.LocalNameTa = *p.LocalNameTa
	}
	if p.HSNCode != nil {
		resp.HSNCode = *p.HSNCode
	}
	if p.CategoryID != nil {
		resp.CategoryID = p.CategoryID.String()
	}
	if p.BrandID != nil {
		resp.BrandID = p.BrandID.String()
	}
	if p.TaxProfileID != nil {
		resp.TaxProfileID = p.TaxProfileID.String()
	}
	if p.PackSize != nil {
		resp.PackSize = p.PackSize.String()
	}
	if p.StandardWeightKg != nil {
		resp.StandardWeightKg = p.StandardWeightKg.String()
	}
	if p.MRP != nil {
		resp.MRP = p.MRP.StringFixed(2)
	}
	if p.SellingPrice != nil {
		resp.SellingPrice = p.SellingPrice.StringFixed(2)
	}
	if p.ReorderLevel != nil {
		resp.ReorderLevel = p.ReorderLevel.String()
	}
	if p.ReorderTarget != nil {
		resp.ReorderTarget = p.ReorderTarget.String()
	}
	if p.MinPriceFloor != nil {
		resp.MinPriceFloor = p.MinPriceFloor.StringFixed(2)
	}
	return resp
}

type productDetailResponse struct {
	productResponse
	Barcodes []string `json:"barcodes"`
	Aliases  []string `json:"aliases"`
}

func toProductDetailResponse(d *product.Detail) productDetailResponse {
	barcodes := make([]string, 0, len(d.Barcodes))
	for _, b := range d.Barcodes {
		barcodes = append(barcodes, b.Barcode)
	}
	aliases := make([]string, 0, len(d.Aliases))
	for _, a := range d.Aliases {
		aliases = append(aliases, a.AliasText)
	}
	return productDetailResponse{
		productResponse: toProductResponse(&d.Product),
		Barcodes:        barcodes,
		Aliases:         aliases,
	}
}

func parseOptionalDecimal(s string) (*decimal.Decimal, error) {
	if s == "" {
		return nil, nil
	}
	d, err := decimal.NewFromString(s)
	if err != nil {
		return nil, err
	}
	return &d, nil
}

func (h *ProductHandlers) Create(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := claimsFromRequest(r)
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}

	var req productRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if req.SKU == "" {
		WriteError(w, reqID, CodeValidation, "sku is required")
		return
	}

	p, ok := req.toProduct(w, reqID)
	if !ok {
		return
	}
	p.SKU = req.SKU

	created, err := h.Product.Create(r.Context(), claims.TenantID, product.CreateInput{
		Product: p, Barcodes: req.Barcodes, Aliases: req.Aliases,
	})
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to create product: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusCreated, toProductResponse(created))
}

func (h *ProductHandlers) Update(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := claimsFromRequest(r)
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid product id")
		return
	}

	var req productRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if req.Name == "" {
		WriteError(w, reqID, CodeValidation, "name is required")
		return
	}

	p, ok := req.toProduct(w, reqID)
	if !ok {
		return
	}

	updated, err := h.Product.Update(r.Context(), claims.TenantID, id, product.UpdateInput{
		Product: p, Barcodes: req.Barcodes, Aliases: req.Aliases,
	})
	if err != nil {
		if errors.Is(err, product.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "product not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to update product: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, toProductResponse(updated))
}

type setProductStatusRequest struct {
	Active bool `json:"active"`
}

// SetStatus activates or deactivates a product — the only supported way to
// remove one from sale/receipt workflows (see product.repository.SetActive's
// doc comment for why a real DELETE is never offered).
func (h *ProductHandlers) SetStatus(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := claimsFromRequest(r)
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid product id")
		return
	}
	var req setProductStatusRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	updated, err := h.Product.SetActive(r.Context(), claims.TenantID, id, req.Active)
	if err != nil {
		if errors.Is(err, product.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "product not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to update product status: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, toProductResponse(updated))
}

func (h *ProductHandlers) Get(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := claimsFromRequest(r)
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid product id")
		return
	}
	d, err := h.Product.GetDetail(r.Context(), claims.TenantID, id)
	if err != nil {
		if errors.Is(err, product.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "product not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to fetch product: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, toProductDetailResponse(d))
}

// List is the master product browse endpoint (distinct from Search, which
// ranks fuzzy matches for point-of-sale lookup): paginated, filterable by
// category and active status, sorted by name.
func (h *ProductHandlers) List(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := claimsFromRequest(r)
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	opts := product.ListOptions{
		Query:      r.URL.Query().Get("q"),
		ActiveOnly: r.URL.Query().Get("active") != "false",
	}
	if v := r.URL.Query().Get("category_id"); v != "" {
		id, err := uuid.Parse(v)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "category_id must be a valid UUID")
			return
		}
		opts.CategoryID = &id
	}
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			opts.Limit = n
		}
	}
	if v := r.URL.Query().Get("offset"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			opts.Offset = n
		}
	}

	result, err := h.Product.List(r.Context(), claims.TenantID, opts)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list products: "+err.Error())
		return
	}
	out := make([]productResponse, 0, len(result.Products))
	for i := range result.Products {
		out = append(out, toProductResponse(&result.Products[i]))
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"products": out, "total": result.Total})
}

func (h *ProductHandlers) Search(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := claimsFromRequest(r)
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	query := r.URL.Query().Get("q")
	var categoryID *uuid.UUID
	if c := r.URL.Query().Get("category_id"); c != "" {
		parsed, err := uuid.Parse(c)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "invalid category_id")
			return
		}
		categoryID = &parsed
	}
	// Both q and category_id are optional: a POS catalog needs to browse the
	// whole active catalog by default (real terminals show every product
	// until the cashier narrows it down, they don't start on a blank
	// screen) exactly the same way browsing one category with no query
	// text does. This is bounded by limit (capped at 50 below), so it can
	// never return more than a page's worth of rows regardless of catalog
	// size.
	limit := 20
	if l := r.URL.Query().Get("limit"); l != "" {
		if parsed, err := strconv.Atoi(l); err == nil {
			limit = parsed
		}
	}

	results, err := h.Product.Search(r.Context(), claims.TenantID, query, categoryID, limit)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "search failed: "+err.Error())
		return
	}

	type searchResultResponse struct {
		Product   productResponse `json:"product"`
		MatchType string          `json:"match_type"`
	}
	out := make([]searchResultResponse, 0, len(results))
	for _, r := range results {
		out = append(out, searchResultResponse{Product: toProductResponse(&r.Product), MatchType: r.MatchType})
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"results": out})
}
