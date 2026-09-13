package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/domain/accounting"
	"github.com/andipatti/feedmate/services/api/internal/domain/inventory"
	"github.com/andipatti/feedmate/services/api/internal/domain/pos"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type POSHandlers struct {
	POS *pos.Service
}

// ListInvoices returns finalized invoices newest-first (the invoice
// history/reprint browse list), optionally filtered by a substring match on
// invoice number or customer name via the `q` query param, paginated via
// `limit`/`offset`.
func (h *POSHandlers) ListInvoices(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	query := r.URL.Query().Get("q")
	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			limit = n
		}
	}
	offset := 0
	if v := r.URL.Query().Get("offset"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			offset = n
		}
	}
	page, err := h.POS.ListInvoices(r.Context(), claims.TenantID, query, limit, offset)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list invoices: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(page.Invoices))
	for _, inv := range page.Invoices {
		row := map[string]interface{}{
			"id":             inv.ID.String(),
			"invoice_number": inv.InvoiceNumber,
			"grand_total":    inv.GrandTotal.StringFixed(2),
			"payment_status": inv.PaymentStatus,
			"status":         inv.Status,
		}
		if inv.CustomerNameSnap != nil {
			row["customer_name"] = *inv.CustomerNameSnap
		}
		if inv.FinalizedAt != nil {
			row["finalized_at"] = inv.FinalizedAt.Format(time.RFC3339)
		}
		out = append(out, row)
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"invoices": out, "total": page.Total})
}

// GetInvoiceDetail returns the full reprint view of one past sale: header,
// lines, and how it was actually paid for.
func (h *POSHandlers) GetInvoiceDetail(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid invoice id")
		return
	}
	detail, err := h.POS.GetInvoiceDetail(r.Context(), claims.TenantID, id)
	if err != nil {
		if errors.Is(err, pos.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "invoice not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to fetch invoice: "+err.Error())
		return
	}

	lines := make([]map[string]interface{}, 0, len(detail.Lines))
	for _, l := range detail.Lines {
		lines = append(lines, map[string]interface{}{
			"id":           l.ID.String(),
			"product_id":   l.ProductID.String(),
			"product_name": l.ProductName,
			"sku":          l.SKU,
			"uom_code":     l.UOMCode,
			"quantity":     l.Quantity.StringFixed(3),
			"unit_price":   l.UnitPrice.StringFixed(2),
			"line_total":   l.LineTotal.StringFixed(2),
		})
	}
	tenders := make([]map[string]interface{}, 0, len(detail.Tenders))
	for _, t := range detail.Tenders {
		row := map[string]interface{}{"method": t.Method, "amount": t.Amount.StringFixed(2)}
		if t.Reference != nil {
			row["reference"] = *t.Reference
		}
		tenders = append(tenders, row)
	}
	header := detail.Header
	resp := map[string]interface{}{
		"id":              header.ID.String(),
		"invoice_number":  header.InvoiceNumber,
		"subtotal":        header.Subtotal.StringFixed(2),
		"discount_total":  header.DiscountTotal.StringFixed(2),
		"taxable_total":   header.TaxableTotal.StringFixed(2),
		"tax_total":       header.TaxTotal.StringFixed(2),
		"rounding_amount": header.RoundingAmount.StringFixed(2),
		"grand_total":     header.GrandTotal.StringFixed(2),
		"payment_status":  header.PaymentStatus,
		"status":          header.Status,
		"lines":           lines,
		"tenders":         tenders,
	}
	if header.CustomerNameSnap != nil {
		resp["customer_name"] = *header.CustomerNameSnap
	}
	if header.FinalizedAt != nil {
		resp["finalized_at"] = header.FinalizedAt.Format(time.RFC3339)
	}
	WriteJSON(w, http.StatusOK, resp)
}

// GetInvoiceForReturn looks an invoice up by its human-facing number (the
// query param `number` — what's printed on the receipt) and returns its
// lines with remaining-eligible-to-return quantities, for the returns
// screen's line picker.
func (h *POSHandlers) GetInvoiceForReturn(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	invoiceNumber := r.URL.Query().Get("number")
	if invoiceNumber == "" {
		WriteError(w, reqID, CodeValidation, "query parameter 'number' is required")
		return
	}
	result, err := h.POS.GetInvoiceForReturn(r.Context(), claims.TenantID, invoiceNumber)
	if err != nil {
		if errors.Is(err, pos.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "invoice not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to fetch invoice: "+err.Error())
		return
	}

	lines := make([]map[string]interface{}, 0, len(result.Lines))
	for _, l := range result.Lines {
		remaining := l.Quantity.Sub(l.AlreadyReturned)
		lines = append(lines, map[string]interface{}{
			"id":                 l.ID.String(),
			"product_id":         l.ProductID.String(),
			"product_name":       l.ProductName,
			"sku":                l.SKU,
			"uom_code":           l.UOMCode,
			"quantity":           l.Quantity.StringFixed(3),
			"unit_price":         l.UnitPrice.StringFixed(2),
			"line_total":         l.LineTotal.StringFixed(2),
			"already_returned":   l.AlreadyReturned.StringFixed(3),
			"remaining_eligible": remaining.StringFixed(3),
		})
	}
	header := result.Header
	WriteJSON(w, http.StatusOK, map[string]interface{}{
		"id":             header.ID.String(),
		"invoice_number": header.InvoiceNumber,
		"grand_total":    header.GrandTotal.StringFixed(2),
		"status":         header.Status,
		"lines":          lines,
	})
}

type finalizeLineRequest struct {
	ProductID         string  `json:"product_id"`
	Quantity          string  `json:"quantity"`
	UnitPriceOverride *string `json:"unit_price_override,omitempty"`
	DiscountAmount    string  `json:"discount_amount,omitempty"`
}

type finalizeTenderRequest struct {
	Method string `json:"method"`
	Amount string `json:"amount"`
}

type finalizeRequest struct {
	ClientTransactionID string                  `json:"client_transaction_id"`
	LocationID          string                  `json:"location_id"`
	CustomerID          string                  `json:"customer_id,omitempty"`
	Lines               []finalizeLineRequest   `json:"lines"`
	Tenders             []finalizeTenderRequest `json:"tenders"`
	OverrideCreditLimit bool                    `json:"override_credit_limit,omitempty"`
	OverrideReason      string                  `json:"override_reason,omitempty"`
}

type finalizeResponse struct {
	InvoiceID     string `json:"invoice_id"`
	InvoiceNumber string `json:"invoice_number"`
	GrandTotal    string `json:"grand_total"`
	Duplicate     bool   `json:"duplicate"`
}

func (h *POSHandlers) FinalizeInvoice(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}

	var req finalizeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}

	clientTxID, err := uuid.Parse(req.ClientTransactionID)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "client_transaction_id must be a valid UUID")
		return
	}
	locationID, err := uuid.Parse(req.LocationID)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "location_id must be a valid UUID")
		return
	}
	if len(req.Lines) == 0 {
		WriteError(w, reqID, CodeValidation, "at least one line is required")
		return
	}

	svcReq := pos.FinalizeRequest{
		ClientTransactionID: clientTxID,
		LocationID:          locationID,
	}

	if req.CustomerID != "" {
		customerID, err := uuid.Parse(req.CustomerID)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "customer_id must be a valid UUID")
			return
		}
		svcReq.CustomerID = &customerID
	}

	for _, l := range req.Lines {
		productID, err := uuid.Parse(l.ProductID)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "line product_id must be a valid UUID")
			return
		}
		qty, err := decimal.NewFromString(l.Quantity)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "line quantity must be a valid decimal")
			return
		}
		discount := decimal.Zero
		if l.DiscountAmount != "" {
			discount, err = decimal.NewFromString(l.DiscountAmount)
			if err != nil {
				WriteError(w, reqID, CodeValidation, "discount_amount must be a valid decimal")
				return
			}
		}
		line := pos.SaleLine{ProductID: productID, Quantity: qty, DiscountAmount: discount}
		if l.UnitPriceOverride != nil {
			price, err := decimal.NewFromString(*l.UnitPriceOverride)
			if err != nil {
				WriteError(w, reqID, CodeValidation, "unit_price_override must be a valid decimal")
				return
			}
			line.UnitPriceOverride = &price
		}
		svcReq.Lines = append(svcReq.Lines, line)
	}

	for _, t := range req.Tenders {
		amount, err := decimal.NewFromString(t.Amount)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "tender amount must be a valid decimal")
			return
		}
		svcReq.Tenders = append(svcReq.Tenders, pos.Tender{Method: t.Method, Amount: amount})
	}

	// A credit-limit override must be an explicit, per-sale operator decision
	// with a reason (PRD 10.1) — never an automatic bypass just because the
	// logged-in role happens to include the credit.override permission.
	if req.OverrideCreditLimit {
		hasPermission := false
		for _, p := range claims.Permissions {
			if p == "credit.override" {
				hasPermission = true
				break
			}
		}
		if !hasPermission {
			WriteError(w, reqID, CodeForbidden, "missing required permission: credit.override")
			return
		}
		if req.OverrideReason == "" {
			WriteError(w, reqID, CodeValidation, "override_reason is required when override_credit_limit is true")
			return
		}
		svcReq.CreditOverride.Requested = true
		svcReq.CreditOverride.Reason = req.OverrideReason
	}

	result, err := h.POS.FinalizeInvoice(r.Context(), claims.TenantID, claims.DeviceID, claims.UserID, svcReq)
	if err != nil {
		switch {
		case errors.Is(err, pos.ErrValidation), errors.Is(err, pos.ErrTenderMismatch), errors.Is(err, pos.ErrNoTaxProfile):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, inventory.ErrInsufficientStock):
			WriteError(w, reqID, CodeInsufficientStock, err.Error())
		case errors.Is(err, pos.ErrCreditLimitExceeded):
			WriteError(w, reqID, CodeCreditLimitExceeded, err.Error())
		case errors.Is(err, accounting.ErrNoActiveFinancialYear):
			WriteError(w, reqID, CodeConflict, "no active financial year is configured for this shop")
		default:
			WriteError(w, reqID, CodeInternal, "failed to finalize invoice: "+err.Error())
		}
		return
	}

	status := http.StatusCreated
	if result.Duplicate {
		status = http.StatusOK
	}
	WriteJSON(w, status, finalizeResponse{
		InvoiceID:     result.InvoiceID.String(),
		InvoiceNumber: result.InvoiceNumber,
		GrandTotal:    result.GrandTotal.StringFixed(2),
		Duplicate:     result.Duplicate,
	})
}
