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

type createProductRequest struct {
	SKU                  string   `json:"sku"`
	Name                 string   `json:"name"`
	LocalNameTa          string   `json:"local_name_ta,omitempty"`
	DefaultSaleUOMID     string   `json:"default_sale_uom_id"`
	DefaultPurchaseUOMID string   `json:"default_purchase_uom_id"`
	BaseInventoryUOMID   string   `json:"base_inventory_uom_id"`
	HSNCode              string   `json:"hsn_code,omitempty"`
	TaxProfileID         string   `json:"tax_profile_id,omitempty"`
	MRP                  string   `json:"mrp,omitempty"`
	SellingPrice         string   `json:"selling_price,omitempty"`
	BatchRequired        bool     `json:"batch_required"`
	ExpiryRequired       bool     `json:"expiry_required"`
	LooseSaleAllowed     bool     `json:"loose_sale_allowed"`
	ScaleRequired        bool     `json:"scale_required"`
	ProductType          string   `json:"product_type,omitempty"`
	Barcodes             []string `json:"barcodes,omitempty"`
	Aliases              []string `json:"aliases,omitempty"`
}

type productResponse struct {
	ID                   string `json:"id"`
	SKU                  string `json:"sku"`
	Name                 string `json:"name"`
	LocalNameTa          string `json:"local_name_ta,omitempty"`
	DefaultSaleUOMID     string `json:"default_sale_uom_id"`
	DefaultPurchaseUOMID string `json:"default_purchase_uom_id"`
	BaseInventoryUOMID   string `json:"base_inventory_uom_id"`
	HSNCode              string `json:"hsn_code,omitempty"`
	MRP                  string `json:"mrp,omitempty"`
	SellingPrice         string `json:"selling_price,omitempty"`
	BatchRequired        bool   `json:"batch_required"`
	ExpiryRequired       bool   `json:"expiry_required"`
	LooseSaleAllowed     bool   `json:"loose_sale_allowed"`
	ScaleRequired        bool   `json:"scale_required"`
	ProductType          string `json:"product_type"`
	Active               bool   `json:"active"`
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
	}
	if p.LocalNameTa != nil {
		resp.LocalNameTa = *p.LocalNameTa
	}
	if p.HSNCode != nil {
		resp.HSNCode = *p.HSNCode
	}
	if p.MRP != nil {
		resp.MRP = p.MRP.StringFixed(2)
	}
	if p.SellingPrice != nil {
		resp.SellingPrice = p.SellingPrice.StringFixed(2)
	}
	return resp
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

	var req createProductRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}

	saleUOM, err1 := uuid.Parse(req.DefaultSaleUOMID)
	purchaseUOM, err2 := uuid.Parse(req.DefaultPurchaseUOMID)
	baseUOM, err3 := uuid.Parse(req.BaseInventoryUOMID)
	if err1 != nil || err2 != nil || err3 != nil {
		WriteError(w, reqID, CodeValidation, "default_sale_uom_id, default_purchase_uom_id, base_inventory_uom_id must be valid UUIDs")
		return
	}

	mrp, err := parseOptionalDecimal(req.MRP)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "mrp must be a valid decimal amount")
		return
	}
	sellingPrice, err := parseOptionalDecimal(req.SellingPrice)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "selling_price must be a valid decimal amount")
		return
	}

	in := product.CreateInput{
		Product: product.Product{
			SKU:                  req.SKU,
			Name:                 req.Name,
			DefaultSaleUOMID:     saleUOM,
			DefaultPurchaseUOMID: purchaseUOM,
			BaseInventoryUOMID:   baseUOM,
			MRP:                  mrp,
			SellingPrice:         sellingPrice,
			BatchRequired:        req.BatchRequired,
			ExpiryRequired:       req.ExpiryRequired,
			LooseSaleAllowed:     req.LooseSaleAllowed,
			ScaleRequired:        req.ScaleRequired,
			ProductType:          req.ProductType,
		},
		Barcodes: req.Barcodes,
		Aliases:  req.Aliases,
	}
	if req.LocalNameTa != "" {
		in.Product.LocalNameTa = &req.LocalNameTa
	}
	if req.HSNCode != "" {
		in.Product.HSNCode = &req.HSNCode
	}
	if req.TaxProfileID != "" {
		taxProfileID, err := uuid.Parse(req.TaxProfileID)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "tax_profile_id must be a valid UUID")
			return
		}
		in.Product.TaxProfileID = &taxProfileID
	}

	created, err := h.Product.Create(r.Context(), claims.TenantID, in)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to create product: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusCreated, toProductResponse(created))
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
	p, err := h.Product.GetByID(r.Context(), claims.TenantID, id)
	if err != nil {
		if errors.Is(err, product.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "product not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to fetch product")
		return
	}
	WriteJSON(w, http.StatusOK, toProductResponse(p))
}

func (h *ProductHandlers) Search(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := claimsFromRequest(r)
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	query := r.URL.Query().Get("q")
	if query == "" {
		WriteError(w, reqID, CodeValidation, "query parameter 'q' is required")
		return
	}
	limit := 20
	if l := r.URL.Query().Get("limit"); l != "" {
		if parsed, err := strconv.Atoi(l); err == nil {
			limit = parsed
		}
	}

	results, err := h.Product.Search(r.Context(), claims.TenantID, query, limit)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "search failed")
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
