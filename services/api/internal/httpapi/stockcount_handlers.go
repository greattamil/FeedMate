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

	"github.com/andipatti/feedmate/services/api/internal/domain/stockcount"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type StockCountHandlers struct {
	StockCount *stockcount.Service
}

type startStockCountRequest struct {
	LocationID string `json:"location_id"`
	CountMode  string `json:"count_mode"`
}

func (h *StockCountHandlers) StartCount(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	var req startStockCountRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	locationID, err := uuid.Parse(req.LocationID)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "location_id must be a valid UUID")
		return
	}
	id, err := h.StockCount.StartCount(r.Context(), claims.TenantID, locationID, claims.UserID, req.CountMode)
	if err != nil {
		if errors.Is(err, stockcount.ErrValidation) {
			WriteError(w, reqID, CodeValidation, err.Error())
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to start stock count: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusCreated, map[string]string{"id": id.String()})
}

type recordCountLineRequest struct {
	ProductID  string `json:"product_id"`
	BatchID    string `json:"batch_id"`
	CountedQty string `json:"counted_qty"`
	Reason     string `json:"reason,omitempty"`
}

func (h *StockCountHandlers) RecordCount(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	stockCountID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid stock count id")
		return
	}
	var req recordCountLineRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	productID, err := uuid.Parse(req.ProductID)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "product_id must be a valid UUID")
		return
	}
	batchID, err := uuid.Parse(req.BatchID)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "batch_id must be a valid UUID")
		return
	}
	countedQty, err := decimal.NewFromString(req.CountedQty)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "counted_qty must be a valid decimal")
		return
	}
	if err := h.StockCount.RecordCount(r.Context(), claims.TenantID, stockCountID, productID, batchID, countedQty, req.Reason); err != nil {
		switch {
		case errors.Is(err, stockcount.ErrValidation):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, stockcount.ErrNotOpen):
			WriteError(w, reqID, CodeConflict, err.Error())
		case errors.Is(err, stockcount.ErrNotFound):
			WriteError(w, reqID, CodeNotFound, "stock count not found")
		default:
			WriteError(w, reqID, CodeInternal, "failed to record count: "+err.Error())
		}
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *StockCountHandlers) PostCount(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	stockCountID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid stock count id")
		return
	}
	result, err := h.StockCount.PostCount(r.Context(), claims.TenantID, stockCountID, claims.UserID, claims.DeviceID)
	if err != nil {
		switch {
		case errors.Is(err, stockcount.ErrNotOpen):
			WriteError(w, reqID, CodeConflict, err.Error())
		case errors.Is(err, stockcount.ErrNotFound):
			WriteError(w, reqID, CodeNotFound, "stock count not found")
		default:
			WriteError(w, reqID, CodeInternal, "failed to post stock count: "+err.Error())
		}
		return
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{
		"lines_adjusted":  result.LinesAdjusted,
		"net_value_delta": result.NetValueDelta.StringFixed(2),
	})
}

func (h *StockCountHandlers) CancelCount(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	stockCountID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid stock count id")
		return
	}
	if err := h.StockCount.CancelCount(r.Context(), claims.TenantID, stockCountID); err != nil {
		switch {
		case errors.Is(err, stockcount.ErrNotOpen):
			WriteError(w, reqID, CodeConflict, err.Error())
		case errors.Is(err, stockcount.ErrNotFound):
			WriteError(w, reqID, CodeNotFound, "stock count not found")
		default:
			WriteError(w, reqID, CodeInternal, "failed to cancel stock count: "+err.Error())
		}
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *StockCountHandlers) ListCounts(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
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
	page, err := h.StockCount.ListCounts(r.Context(), claims.TenantID, limit, offset)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list stock counts: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(page.Counts))
	for _, c := range page.Counts {
		row := map[string]interface{}{
			"id":            c.ID.String(),
			"location_name": c.LocationName,
			"count_mode":    c.CountMode,
			"status":        c.Status,
			"started_at":    c.StartedAt.Format(time.RFC3339),
		}
		if c.CompletedAt != nil {
			row["completed_at"] = c.CompletedAt.Format(time.RFC3339)
		}
		out = append(out, row)
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"stock_counts": out, "total": page.Total})
}

// ListBatchesForProduct lists a product's active batches at a stock count's
// location — what the count-line form needs to let the user pick which
// physical batch they are recording a count against.
func (h *StockCountHandlers) ListBatchesForProduct(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	stockCountID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid stock count id")
		return
	}
	productID, err := uuid.Parse(r.URL.Query().Get("product_id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "product_id must be a valid UUID")
		return
	}
	detail, err := h.StockCount.GetCountDetail(r.Context(), claims.TenantID, stockCountID)
	if err != nil {
		if errors.Is(err, stockcount.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "stock count not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to fetch stock count: "+err.Error())
		return
	}
	batches, err := h.StockCount.ListBatchesForProduct(r.Context(), claims.TenantID, productID, detail.Count.LocationID)
	if err != nil {
		WriteError(w, reqID, CodeInternal, "failed to list batches: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(batches))
	for _, b := range batches {
		out = append(out, map[string]interface{}{
			"id":            b.ID.String(),
			"batch_code":    b.BatchCode,
			"available_qty": b.AvailableQty.StringFixed(3),
		})
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"batches": out})
}

func (h *StockCountHandlers) GetCountDetail(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	stockCountID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "invalid stock count id")
		return
	}
	detail, err := h.StockCount.GetCountDetail(r.Context(), claims.TenantID, stockCountID)
	if err != nil {
		if errors.Is(err, stockcount.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "stock count not found")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to fetch stock count: "+err.Error())
		return
	}
	lines := make([]map[string]interface{}, 0, len(detail.Lines))
	for _, l := range detail.Lines {
		row := map[string]interface{}{
			"id":           l.ID.String(),
			"product_id":   l.ProductID.String(),
			"product_name": l.ProductName,
			"sku":          l.SKU,
			"batch_id":     l.BatchID.String(),
			"batch_code":   l.BatchCode,
			"expected_qty": l.ExpectedQty.StringFixed(3),
			"counted_qty":  l.CountedQty.StringFixed(3),
			"variance_qty": l.VarianceQty.StringFixed(3),
		}
		if l.Reason != nil {
			row["reason"] = *l.Reason
		}
		lines = append(lines, row)
	}
	resp := map[string]interface{}{
		"id":          detail.Count.ID.String(),
		"location_id": detail.Count.LocationID.String(),
		"count_mode":  detail.Count.CountMode,
		"status":      detail.Count.Status,
		"started_at":  detail.Count.StartedAt.Format(time.RFC3339),
		"lines":       lines,
	}
	if detail.Count.CompletedAt != nil {
		resp["completed_at"] = detail.Count.CompletedAt.Format(time.RFC3339)
	}
	WriteJSON(w, http.StatusOK, resp)
}
