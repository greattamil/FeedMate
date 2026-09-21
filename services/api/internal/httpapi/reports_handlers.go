package httpapi

import (
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/andipatti/feedmate/services/api/internal/domain/reports"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type ReportsHandlers struct {
	Reports *reports.Service
}

func parseDateParam(r *http.Request, name string, def time.Time) (time.Time, error) {
	v := r.URL.Query().Get(name)
	if v == "" {
		return def, nil
	}
	return time.Parse("2006-01-02", v)
}

func (h *ReportsHandlers) SalesSummary(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	today := time.Now().UTC().Truncate(24 * time.Hour)
	dateFrom, err := parseDateParam(r, "date_from", today)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "date_from must be YYYY-MM-DD")
		return
	}
	dateTo, err := parseDateParam(r, "date_to", today)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "date_to must be YYYY-MM-DD")
		return
	}

	summary, err := h.Reports.SalesSummary(r.Context(), claims.TenantID, dateFrom, dateTo)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to compute sales summary: "+err.Error())
		return
	}

	byTender := make([]map[string]string, 0, len(summary.ByTender))
	for _, t := range summary.ByTender {
		byTender = append(byTender, map[string]string{"method": t.Method, "total": t.Total.StringFixed(2)})
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{
		"invoice_count":  summary.InvoiceCount,
		"gross_sales":    summary.GrossSales.StringFixed(2),
		"discount_total": summary.DiscountTotal.StringFixed(2),
		"tax_total":      summary.TaxTotal.StringFixed(2),
		"net_sales":      summary.NetSales.StringFixed(2),
		"by_tender":      byTender,
	})
}

func (h *ReportsHandlers) StockOnHand(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	var locationID *uuid.UUID
	if v := r.URL.Query().Get("location_id"); v != "" {
		id, err := uuid.Parse(v)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "location_id must be a valid UUID")
			return
		}
		locationID = &id
	}

	lines, err := h.Reports.StockOnHand(r.Context(), claims.TenantID, locationID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to compute stock on hand: "+err.Error())
		return
	}

	out := make([]map[string]interface{}, 0, len(lines))
	for _, l := range lines {
		item := map[string]interface{}{
			"product_id":             l.ProductID.String(),
			"sku":                    l.SKU,
			"name":                   l.ProductName,
			"total_available":        l.TotalAvailable.StringFixed(3),
			"batch_count":            l.BatchCount,
			"expiring_within_30_days": l.ExpiringWithin30Days,
		}
		if l.NearestExpiry != nil {
			item["nearest_expiry"] = l.NearestExpiry.Format("2006-01-02")
		}
		out = append(out, item)
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"products": out})
}

// StockSummary lists every active product with its live on-hand quantity
// and reorder status, for the Stock Management screen and any other
// screen (product list, POS catalog) that wants to show real stock rather
// than nothing.
func (h *ReportsHandlers) StockSummary(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	var locationID *uuid.UUID
	if v := r.URL.Query().Get("location_id"); v != "" {
		id, err := uuid.Parse(v)
		if err != nil {
			WriteError(w, reqID, CodeValidation, "location_id must be a valid UUID")
			return
		}
		locationID = &id
	}

	lines, err := h.Reports.StockSummary(r.Context(), claims.TenantID, locationID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to compute stock summary: "+err.Error())
		return
	}

	out := make([]map[string]interface{}, 0, len(lines))
	lowStockCount, outOfStockCount := 0, 0
	for _, l := range lines {
		item := map[string]interface{}{
			"product_id":          l.ProductID.String(),
			"sku":                 l.SKU,
			"name":                l.ProductName,
			"uom_code":            l.UOMCode,
			"on_hand_qty":         l.OnHandQty.StringFixed(3),
			"status":              l.Status,
			"stock_alert_enabled": l.AlertsEnabled,
		}
		if l.ReorderLevel != nil {
			item["reorder_level"] = l.ReorderLevel.StringFixed(3)
		}
		if l.ReorderTarget != nil {
			item["reorder_target"] = l.ReorderTarget.StringFixed(3)
		}
		// A product with alerts turned off still reports its real,
		// factual Status above (never hidden or faked as "OK") — it's
		// simply excluded from the aggregate counts that drive the
		// dashboard's low-stock banner, which is the whole point of the
		// per-product control (see product.Product.StockAlertEnabled).
		if l.AlertsEnabled {
			if l.Status == "LOW_STOCK" {
				lowStockCount++
			} else if l.Status == "OUT_OF_STOCK" {
				outOfStockCount++
			}
		}
		out = append(out, item)
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{
		"products":          out,
		"low_stock_count":   lowStockCount,
		"out_of_stock_count": outOfStockCount,
	})
}

func (h *ReportsHandlers) CustomerBalances(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	balances, err := h.Reports.CustomerBalances(r.Context(), claims.TenantID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to compute customer balances: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(balances))
	for _, b := range balances {
		out = append(out, map[string]interface{}{
			"customer_id":  b.CustomerID.String(),
			"name":         b.Name,
			"balance":      b.Balance.StringFixed(2),
			"credit_limit": b.CreditLimit.StringFixed(2),
		})
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"customers": out})
}

func (h *ReportsHandlers) EODHistory(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	today := time.Now().UTC().Truncate(24 * time.Hour)
	dateFrom, err := parseDateParam(r, "date_from", today.AddDate(0, 0, -30))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "date_from must be YYYY-MM-DD")
		return
	}
	dateTo, err := parseDateParam(r, "date_to", today)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "date_to must be YYYY-MM-DD")
		return
	}

	history, err := h.Reports.EODHistory(r.Context(), claims.TenantID, dateFrom, dateTo)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to fetch EOD history: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(history))
	for _, e := range history {
		item := map[string]interface{}{
			"business_date": e.BusinessDate.Format("2006-01-02"),
			"opening_cash":  e.OpeningCash.StringFixed(2),
			"cash_sales":    e.CashSales.StringFixed(2),
			"cash_refunds":  e.CashRefunds.StringFixed(2),
			"expected_cash": e.ExpectedCash.StringFixed(2),
			"status":        e.Status,
		}
		if e.ActualCash != nil {
			item["actual_cash"] = e.ActualCash.StringFixed(2)
		}
		if e.Variance != nil {
			item["variance"] = e.Variance.StringFixed(2)
		}
		out = append(out, item)
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"sessions": out})
}
