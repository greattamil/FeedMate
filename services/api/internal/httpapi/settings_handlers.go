package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/andipatti/feedmate/services/api/internal/domain/settings"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

// SettingsHandlers exposes the Store Settings screen: the shop profile
// fields onboarding a real tenant needs (legal/trade name, GSTIN, FSSAI
// license, contact, address, invoice prefix) plus receipt header/footer
// text, none of which had an app-facing UI before this.
type SettingsHandlers struct {
	Settings *settings.Service
}

func storeProfileToJSON(p settings.StoreProfile) map[string]interface{} {
	return map[string]interface{}{
		"legal_name":       p.LegalName,
		"trade_name":       p.TradeName,
		"gstin":            p.GSTIN,
		"fssai_license_no": p.FSSAILicenseNo,
		"phone":            p.Phone,
		"email":            p.Email,
		"address_line1":    p.AddressLine1,
		"address_line2":    p.AddressLine2,
		"city":             p.City,
		"district":         p.District,
		"state_code":       p.StateCode,
		"postal_code":      p.PostalCode,
		"invoice_prefix":   p.InvoicePrefix,
		"receipt_header":   p.ReceiptHeader,
		"receipt_footer":   p.ReceiptFooter,
		"logo_data_uri":    p.LogoDataURI,
	}
}

func (h *SettingsHandlers) GetStoreProfile(w http.ResponseWriter, r *http.Request) {
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, r, CodeUnauthorized, "authentication required")
		return
	}
	p, err := h.Settings.GetStoreProfile(r.Context(), claims.TenantID)
	if err != nil {
		WriteError(w, r, CodeInternal, "failed to load store profile: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, storeProfileToJSON(p))
}

type updateStoreProfileRequest struct {
	LegalName      string  `json:"legal_name"`
	TradeName      *string `json:"trade_name"`
	GSTIN          *string `json:"gstin"`
	FSSAILicenseNo *string `json:"fssai_license_no"`
	Phone          *string `json:"phone"`
	Email          *string `json:"email"`
	AddressLine1   string  `json:"address_line1"`
	AddressLine2   *string `json:"address_line2"`
	City           string  `json:"city"`
	District       *string `json:"district"`
	StateCode      string  `json:"state_code"`
	PostalCode     *string `json:"postal_code"`
	InvoicePrefix  string  `json:"invoice_prefix"`
	ReceiptHeader  *string `json:"receipt_header"`
	ReceiptFooter  *string `json:"receipt_footer"`
	LogoDataURI    *string `json:"logo_data_uri"`
}

func (h *SettingsHandlers) UpdateStoreProfile(w http.ResponseWriter, r *http.Request) {
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, r, CodeUnauthorized, "authentication required")
		return
	}
	var req updateStoreProfileRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, r, CodeValidation, "invalid request body")
		return
	}
	p := settings.StoreProfile{
		LegalName:      req.LegalName,
		TradeName:      req.TradeName,
		GSTIN:          req.GSTIN,
		FSSAILicenseNo: req.FSSAILicenseNo,
		Phone:          req.Phone,
		Email:          req.Email,
		AddressLine1:   req.AddressLine1,
		AddressLine2:   req.AddressLine2,
		City:           req.City,
		District:       req.District,
		StateCode:      req.StateCode,
		PostalCode:     req.PostalCode,
		InvoicePrefix:  req.InvoicePrefix,
		ReceiptHeader:  req.ReceiptHeader,
		ReceiptFooter:  req.ReceiptFooter,
		LogoDataURI:    req.LogoDataURI,
	}
	if err := h.Settings.UpdateStoreProfile(r.Context(), claims.TenantID, claims.UserID, p); err != nil {
		if errors.Is(err, settings.ErrValidation) {
			WriteError(w, r, CodeValidation, err.Error())
			return
		}
		WriteError(w, r, CodeInternal, "failed to update store profile: "+err.Error())
		return
	}
	updated, err := h.Settings.GetStoreProfile(r.Context(), claims.TenantID)
	if err != nil {
		WriteError(w, r, CodeInternal, "failed to reload store profile: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, storeProfileToJSON(updated))
}

func (h *SettingsHandlers) GetNotificationPrefs(w http.ResponseWriter, r *http.Request) {
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, r, CodeUnauthorized, "authentication required")
		return
	}
	p, err := h.Settings.GetNotificationPrefs(r.Context(), claims.TenantID)
	if err != nil {
		WriteError(w, r, CodeInternal, "failed to load notification preferences: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, p)
}

func (h *SettingsHandlers) UpdateNotificationPrefs(w http.ResponseWriter, r *http.Request) {
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, r, CodeUnauthorized, "authentication required")
		return
	}
	var p settings.NotificationPrefs
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		WriteError(w, r, CodeValidation, "invalid request body")
		return
	}
	if err := h.Settings.UpdateNotificationPrefs(r.Context(), claims.TenantID, claims.UserID, p); err != nil {
		WriteError(w, r, CodeInternal, "failed to update notification preferences: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, p)
}
