package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/domain/accounting"
	"github.com/andipatti/feedmate/services/api/internal/domain/procurement"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type ProcurementHandlers struct {
	Procurement *procurement.Service
}

type grnLineRequest struct {
	ProductID            string  `json:"product_id"`
	BatchCode            string  `json:"batch_code"`
	ManufactureDate      *string `json:"manufacture_date,omitempty"`
	ExpiryDate           *string `json:"expiry_date,omitempty"`
	ReceivedQty          string  `json:"received_qty"`
	UOMID                string  `json:"uom_id"`
	LocationID           string  `json:"location_id"`
	UnitCost             string  `json:"unit_cost"`
	TaxProfileID         *string `json:"tax_profile_id,omitempty"`
	QualityStatus        string  `json:"quality_status,omitempty"`
	GrossWeightKg        *string `json:"gross_weight_kg,omitempty"`
	TareMethod           string  `json:"tare_method,omitempty"`
	MeasuredTareKg       *string `json:"measured_tare_kg,omitempty"`
	BagCount             *int    `json:"bag_count,omitempty"`
	StandardTarePerBagKg *string `json:"standard_tare_per_bag_kg,omitempty"`
}

type postGRNRequest struct {
	SupplierID          string           `json:"supplier_id"`
	PurchaseOrderID     string           `json:"purchase_order_id,omitempty"`
	SupplierDocumentNo  string           `json:"supplier_document_no,omitempty"`
	VehicleNo           string           `json:"vehicle_no,omitempty"`
	Lines               []grnLineRequest `json:"lines"`
	OverrideTare        bool             `json:"override_tare,omitempty"`
	OverrideTareReason  string           `json:"override_tare_reason,omitempty"`
}

func parseDate(s *string) (*time.Time, error) {
	if s == nil || *s == "" {
		return nil, nil
	}
	t, err := time.Parse("2006-01-02", *s)
	if err != nil {
		return nil, err
	}
	return &t, nil
}

func (h *ProcurementHandlers) PostGRN(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}

	var req postGRNRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	if len(req.Lines) == 0 {
		WriteError(w, reqID, CodeValidation, "at least one line is required")
		return
	}

	supplierID, err := uuid.Parse(req.SupplierID)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "supplier_id must be a valid UUID")
		return
	}

	svcReq := procurement.PostGRNRequest{SupplierID: supplierID}
	if req.PurchaseOrderID != "" {
		poID, err := uuid.Parse(req.PurchaseOrderID)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "purchase_order_id must be a valid UUID")
			return
		}
		svcReq.PurchaseOrderID = &poID
	}
	if req.SupplierDocumentNo != "" {
		svcReq.SupplierDocumentNo = &req.SupplierDocumentNo
	}
	if req.VehicleNo != "" {
		svcReq.VehicleNo = &req.VehicleNo
	}

	if req.OverrideTare {
		hasPermission := false
		for _, p := range claims.Permissions {
			if p == "grn.override_tare" {
				hasPermission = true
				break
			}
		}
		if !hasPermission {
			WriteError(w, reqID, CodeForbidden, "missing required permission: grn.override_tare")
			return
		}
		if req.OverrideTareReason == "" {
			WriteError(w, reqID, CodeValidation, "override_tare_reason is required when override_tare is true")
			return
		}
		svcReq.TareOverride.Requested = true
		svcReq.TareOverride.Reason = req.OverrideTareReason
	}

	for _, l := range req.Lines {
		productID, err := uuid.Parse(l.ProductID)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "line product_id must be a valid UUID")
			return
		}
		uomID, err := uuid.Parse(l.UOMID)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "line uom_id must be a valid UUID")
			return
		}
		locationID, err := uuid.Parse(l.LocationID)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "line location_id must be a valid UUID")
			return
		}
		qty, err := decimal.NewFromString(l.ReceivedQty)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "received_qty must be a valid decimal")
			return
		}
		unitCost, err := decimal.NewFromString(l.UnitCost)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "unit_cost must be a valid decimal")
			return
		}
		manufactureDate, err := parseDate(l.ManufactureDate)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "manufacture_date must be YYYY-MM-DD")
			return
		}
		expiryDate, err := parseDate(l.ExpiryDate)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "expiry_date must be YYYY-MM-DD")
			return
		}

		line := procurement.GRNLineInput{
			ProductID: productID, BatchCode: l.BatchCode, ManufactureDate: manufactureDate, ExpiryDate: expiryDate,
			ReceivedQty: qty, UOMID: uomID, LocationID: locationID, UnitCost: unitCost,
			QualityStatus: l.QualityStatus, TareMethod: l.TareMethod,
		}
		if l.TaxProfileID != nil {
			taxProfileID, err := uuid.Parse(*l.TaxProfileID)
			if err != nil {
				WriteError(w, reqID, CodeValidation, "tax_profile_id must be a valid UUID")
				return
			}
			line.TaxProfileID = &taxProfileID
		}
		if l.GrossWeightKg != nil {
			gross, err := decimal.NewFromString(*l.GrossWeightKg)
			if err != nil {
				WriteError(w, reqID, CodeValidation, "gross_weight_kg must be a valid decimal")
				return
			}
			line.GrossWeightKg = &gross
		}
		if l.MeasuredTareKg != nil {
			tare, err := decimal.NewFromString(*l.MeasuredTareKg)
			if err != nil {
				WriteError(w, reqID, CodeValidation, "measured_tare_kg must be a valid decimal")
				return
			}
			line.MeasuredTareKg = &tare
		}
		if l.StandardTarePerBagKg != nil {
			tarePerBag, err := decimal.NewFromString(*l.StandardTarePerBagKg)
			if err != nil {
				WriteError(w, reqID, CodeValidation, "standard_tare_per_bag_kg must be a valid decimal")
				return
			}
			line.StandardTarePerBagKg = &tarePerBag
		}
		line.BagCount = l.BagCount

		svcReq.Lines = append(svcReq.Lines, line)
	}

	result, err := h.Procurement.PostGRN(r.Context(), claims.TenantID, claims.DeviceID, claims.UserID, svcReq)
	if err != nil {
		switch {
		case errors.Is(err, procurement.ErrValidation), errors.Is(err, procurement.ErrTareNegativeNet):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, procurement.ErrTareExceedsThreshold):
			WriteError(w, reqID, CodeConflict, err.Error())
		case errors.Is(err, accounting.ErrNoActiveFinancialYear):
			WriteError(w, reqID, CodeConflict, "no active financial year is configured for this shop")
		default:
			WriteError(w, reqID, CodeInternal, "failed to post GRN")
		}
		return
	}

	WriteJSON(w, http.StatusCreated, map[string]string{
		"grn_id":     result.GRNID.String(),
		"grn_number": result.GRNNumber,
	})
}
