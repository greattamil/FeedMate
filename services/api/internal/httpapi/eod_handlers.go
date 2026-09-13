package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/domain/eod"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type EODHandlers struct {
	EOD *eod.Service
}

func parseBusinessDate(s string) (time.Time, error) {
	if s == "" {
		return time.Now(), nil
	}
	return time.Parse("2006-01-02", s)
}

type openEODRequest struct {
	BusinessDate string `json:"business_date,omitempty"` // defaults to today
	OpeningCash  string `json:"opening_cash"`
}

func (h *EODHandlers) OpenSession(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	var req openEODRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	businessDate, err := parseBusinessDate(req.BusinessDate)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "business_date must be YYYY-MM-DD")
		return
	}
	openingCash, err := decimal.NewFromString(req.OpeningCash)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "opening_cash must be a valid decimal")
		return
	}

	sessionID, err := h.EOD.OpenSession(r.Context(), claims.TenantID, claims.DeviceID, claims.UserID, businessDate, openingCash)
	if err != nil {
		switch {
		case errors.Is(err, eod.ErrValidation):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, eod.ErrSessionExists):
			WriteError(w, reqID, CodeConflict, err.Error())
		default:
			WriteError(w, reqID, CodeInternal, "failed to open EOD session: "+err.Error())
		}
		return
	}
	WriteJSON(w, http.StatusCreated, map[string]string{"session_id": sessionID.String()})
}

type closeEODRequest struct {
	BusinessDate   string `json:"business_date,omitempty"`
	ActualCash     string `json:"actual_cash"`
	VarianceReason string `json:"variance_reason,omitempty"`
}

func (h *EODHandlers) CloseSession(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	var req closeEODRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	businessDate, err := parseBusinessDate(req.BusinessDate)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "business_date must be YYYY-MM-DD")
		return
	}
	actualCash, err := decimal.NewFromString(req.ActualCash)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "actual_cash must be a valid decimal")
		return
	}

	result, err := h.EOD.CloseSession(r.Context(), claims.TenantID, claims.UserID, businessDate, actualCash, req.VarianceReason)
	if err != nil {
		switch {
		case errors.Is(err, eod.ErrValidation):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, eod.ErrSessionNotOpen), errors.Is(err, eod.ErrNotFound):
			WriteError(w, reqID, CodeConflict, err.Error())
		default:
			WriteError(w, reqID, CodeInternal, "failed to close EOD session: "+err.Error())
		}
		return
	}
	WriteJSON(w, http.StatusOK, map[string]string{
		"session_id":    result.SessionID.String(),
		"expected_cash": result.ExpectedCash.StringFixed(2),
		"actual_cash":   result.ActualCash.StringFixed(2),
		"variance":      result.Variance.StringFixed(2),
	})
}

type reopenEODRequest struct {
	BusinessDate string `json:"business_date,omitempty"`
	Reason       string `json:"reason"`
}

func (h *EODHandlers) ReopenSession(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	var req reopenEODRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	businessDate, err := parseBusinessDate(req.BusinessDate)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "business_date must be YYYY-MM-DD")
		return
	}

	if err := h.EOD.ReopenSession(r.Context(), claims.TenantID, claims.UserID, businessDate, req.Reason); err != nil {
		switch {
		case errors.Is(err, eod.ErrValidation):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, eod.ErrNotClosed), errors.Is(err, eod.ErrNotFound):
			WriteError(w, reqID, CodeConflict, err.Error())
		default:
			WriteError(w, reqID, CodeInternal, "failed to reopen EOD session: "+err.Error())
		}
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type recordCashMovementRequest struct {
	BusinessDate string `json:"business_date,omitempty"`
	MovementType string `json:"movement_type"`
	Direction    string `json:"direction"`
	Amount       string `json:"amount"`
	Reason       string `json:"reason,omitempty"`
}

// RecordCashMovement logs a manual cash in/out (petty cash) against the
// current OPEN EOD session — e.g. cash taken out for an expense, or extra
// change added to the drawer. Counts toward expected cash the next time the
// session is closed (see eod.Service.CloseSession).
func (h *EODHandlers) RecordCashMovement(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	var req recordCashMovementRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		WriteError(w, reqID, CodeValidation, "invalid request body")
		return
	}
	businessDate, err := parseBusinessDate(req.BusinessDate)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "business_date must be YYYY-MM-DD")
		return
	}
	amount, err := decimal.NewFromString(req.Amount)
	if err != nil {
		WriteError(w, reqID, CodeValidation, "amount must be a valid decimal")
		return
	}

	id, err := h.EOD.RecordCashMovement(r.Context(), claims.TenantID, claims.UserID, businessDate, req.MovementType, req.Direction, amount, req.Reason)
	if err != nil {
		switch {
		case errors.Is(err, eod.ErrValidation):
			WriteError(w, reqID, CodeValidation, err.Error())
		case errors.Is(err, eod.ErrSessionNotOpen), errors.Is(err, eod.ErrNotFound):
			WriteError(w, reqID, CodeConflict, err.Error())
		default:
			WriteError(w, reqID, CodeInternal, "failed to record cash movement: "+err.Error())
		}
		return
	}
	WriteJSON(w, http.StatusCreated, map[string]string{"movement_id": id.String()})
}

// ListCashMovements returns the current (or given) business date's manual
// cash in/out log, newest-first.
func (h *EODHandlers) ListCashMovements(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	businessDate, err := parseBusinessDate(r.URL.Query().Get("business_date"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "business_date must be YYYY-MM-DD")
		return
	}
	movements, err := h.EOD.ListCashMovements(r.Context(), claims.TenantID, businessDate)
	if err != nil {
		if errors.Is(err, eod.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "no EOD session for this business date")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to list cash movements: "+err.Error())
		return
	}
	out := make([]map[string]interface{}, 0, len(movements))
	for _, m := range movements {
		row := map[string]interface{}{
			"id":            m.ID.String(),
			"movement_type": m.MovementType,
			"direction":     m.Direction,
			"amount":        m.Amount.StringFixed(2),
			"created_at":    m.CreatedAt.Format(time.RFC3339),
		}
		if m.Reason != nil {
			row["reason"] = *m.Reason
		}
		out = append(out, row)
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"movements": out})
}

func (h *EODHandlers) GetSession(w http.ResponseWriter, r *http.Request) {
	reqID := reqctx.RequestID(r.Context())
	claims, ok := reqctx.Claims(r.Context())
	if !ok {
		WriteError(w, reqID, CodeUnauthorized, "authentication required")
		return
	}
	businessDate, err := parseBusinessDate(r.URL.Query().Get("business_date"))
	if err != nil {
		WriteError(w, reqID, CodeValidation, "business_date must be YYYY-MM-DD")
		return
	}
	session, err := h.EOD.GetSession(r.Context(), claims.TenantID, businessDate)
	if err != nil {
		if errors.Is(err, eod.ErrNotFound) {
			WriteError(w, reqID, CodeNotFound, "no EOD session for this business date")
			return
		}
		WriteError(w, reqID, CodeInternal, "failed to fetch EOD session: "+err.Error())
		return
	}
	resp := map[string]interface{}{
		"session_id":    session.ID.String(),
		"business_date": session.BusinessDate.Format("2006-01-02"),
		"opening_cash":  session.OpeningCash.StringFixed(2),
		"cash_sales":    session.CashSales.StringFixed(2),
		"cash_refunds":  session.CashRefunds.StringFixed(2),
		"expected_cash": session.ExpectedCash.StringFixed(2),
		"status":        session.Status,
	}
	if session.ActualCash != nil {
		resp["actual_cash"] = session.ActualCash.StringFixed(2)
	}
	if session.Variance != nil {
		resp["variance"] = session.Variance.StringFixed(2)
	}
	WriteJSON(w, http.StatusOK, resp)
}
