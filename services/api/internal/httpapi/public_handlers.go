package httpapi

import (
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/product"
	"github.com/andipatti/feedmate/services/api/internal/domain/settings"
)

// PublicHandlers serves data to the outside world with no login at all —
// today just the marketing website's product/price/stock catalog. Unlike
// every other handler group, this one is pinned to exactly one tenant via
// server config (PublicWebsiteTenantID), never a request parameter, so a
// visitor can never choose whose data they see — see GetPublicCatalog.
type PublicHandlers struct {
	DB *dbctx.DB
	// PublicWebsiteTenantID is nil when PUBLIC_WEBSITE_TENANT_ID is unset
	// or invalid — GetPublicCatalog then fails closed (500), never
	// guessing a tenant.
	PublicWebsiteTenantID *uuid.UUID
}

type publicStoreResponse struct {
	Name           string  `json:"name"`
	Phone          *string `json:"phone,omitempty"`
	AddressLine1   string  `json:"address_line1"`
	AddressLine2   *string `json:"address_line2,omitempty"`
	City           string  `json:"city"`
	District       *string `json:"district,omitempty"`
	StateCode      string  `json:"state_code"`
	PostalCode     *string `json:"postal_code,omitempty"`
	GSTIN          *string `json:"gstin,omitempty"`
	FSSAILicenseNo *string `json:"fssai_license_no,omitempty"`
	LogoDataURI    *string `json:"logo_data_uri,omitempty"`
}

type publicCatalogItemResponse struct {
	Name         string  `json:"name"`
	LocalNameTa  *string `json:"local_name_ta,omitempty"`
	Category     *string `json:"category,omitempty"`
	PackSize     *string `json:"pack_size,omitempty"`
	MRP          *string `json:"mrp,omitempty"`
	SellingPrice *string `json:"selling_price,omitempty"`
	InStock      bool    `json:"in_stock"`
}

type publicCatalogResponse struct {
	Store     publicStoreResponse         `json:"store"`
	Products  []publicCatalogItemResponse `json:"products"`
	UpdatedAt string                      `json:"updated_at"`
}

// GetPublicCatalog is the marketing website's only connection to the ERP —
// a read-only, cacheable snapshot of store identity plus whichever products
// a shop has explicitly opted into (product.ShowOnWebsite — see migration
// 0032's doc comment on why that is opt-in, not opt-out). Deliberately
// unauthenticated (same pattern as GetBranding/RegisterDevice — see their
// doc comments): the website's browser-side fetch carries no JWT at all.
//
// Scoping is done via dbctx.WithAdminTenantTx (see that function's own doc
// comment for why it's safe) with PublicWebsiteTenantID, a value read from
// server config at startup, never from the request — so nothing a visitor
// sends can change whose data comes back.
//
// Cache-Control lets Cloudflare's edge cache this response for ~2 minutes,
// so repeat visits don't reach Cloud Run at all (important given Cloud
// Run's scale-to-zero + max-instances=1 config — see deploy/gcp/deploy-api.sh).
func (h *PublicHandlers) GetPublicCatalog(w http.ResponseWriter, r *http.Request) {
	if h.PublicWebsiteTenantID == nil {
		WriteError(w, r, CodeInternal, "public catalog is not configured")
		return
	}

	var resp publicCatalogResponse
	err := h.DB.WithAdminTenantTx(r.Context(), *h.PublicWebsiteTenantID, func(tx pgx.Tx) error {
		profile, err := settings.GetStoreProfile(r.Context(), tx, *h.PublicWebsiteTenantID)
		if err != nil {
			return err
		}
		items, err := product.ListPublicCatalog(r.Context(), tx)
		if err != nil {
			return err
		}

		resp.Store = publicStoreResponse{
			Name:           profile.LegalName,
			Phone:          profile.Phone,
			AddressLine1:   profile.AddressLine1,
			AddressLine2:   profile.AddressLine2,
			City:           profile.City,
			District:       profile.District,
			StateCode:      profile.StateCode,
			PostalCode:     profile.PostalCode,
			GSTIN:          profile.GSTIN,
			FSSAILicenseNo: profile.FSSAILicenseNo,
			LogoDataURI:    profile.LogoDataURI,
		}
		if profile.TradeName != nil && *profile.TradeName != "" {
			resp.Store.Name = *profile.TradeName
		}

		resp.Products = make([]publicCatalogItemResponse, 0, len(items))
		for _, it := range items {
			out := publicCatalogItemResponse{
				Name:        it.Name,
				LocalNameTa: it.LocalNameTa,
				Category:    it.CategoryName,
				InStock:     it.InStock,
			}
			if it.PackSize != nil {
				s := it.PackSize.String()
				out.PackSize = &s
			}
			if it.MRP != nil {
				s := it.MRP.StringFixed(2)
				out.MRP = &s
			}
			if it.SellingPrice != nil {
				s := it.SellingPrice.StringFixed(2)
				out.SellingPrice = &s
			}
			resp.Products = append(resp.Products, out)
		}
		return nil
	})
	if err != nil {
		WriteError(w, r, CodeInternal, "failed to load public catalog: "+err.Error())
		return
	}

	resp.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	w.Header().Set("Cache-Control", "public, max-age=120")
	WriteJSON(w, http.StatusOK, resp)
}
