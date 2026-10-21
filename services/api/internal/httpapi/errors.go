package httpapi

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

// ErrorCode is the machine-readable error taxonomy from the master API error
// contract (PRD A21). Clients branch on this, never on the message string.
type ErrorCode string

const (
	CodeValidation          ErrorCode = "VALIDATION_ERROR"
	CodeUnauthorized        ErrorCode = "UNAUTHORIZED"
	CodeForbidden           ErrorCode = "FORBIDDEN"
	CodeTenantContext       ErrorCode = "TENANT_CONTEXT_ERROR"
	CodeConflict            ErrorCode = "CONFLICT"
	CodeIdempotencyConflict ErrorCode = "IDEMPOTENCY_CONFLICT"
	CodeInsufficientStock   ErrorCode = "INSUFFICIENT_STOCK"
	CodeCreditLimitExceeded ErrorCode = "CREDIT_LIMIT_EXCEEDED"
	CodePaymentPending      ErrorCode = "PAYMENT_PENDING"
	CodePaymentUnknown      ErrorCode = "PAYMENT_UNKNOWN"
	CodeCompliancePending   ErrorCode = "COMPLIANCE_PENDING"
	CodeArchiveHold         ErrorCode = "ARCHIVE_HOLD"
	CodeNotFound            ErrorCode = "NOT_FOUND"
	CodeInternal            ErrorCode = "INTERNAL_ERROR"
)

var httpStatusByCode = map[ErrorCode]int{
	CodeValidation:          http.StatusBadRequest,
	CodeUnauthorized:        http.StatusUnauthorized,
	CodeForbidden:           http.StatusForbidden,
	CodeTenantContext:       http.StatusForbidden,
	CodeConflict:            http.StatusConflict,
	CodeIdempotencyConflict: http.StatusConflict,
	CodeInsufficientStock:   http.StatusConflict,
	CodeCreditLimitExceeded: http.StatusConflict,
	CodePaymentPending:      http.StatusAccepted,
	CodePaymentUnknown:      http.StatusConflict,
	CodeCompliancePending:   http.StatusAccepted,
	CodeArchiveHold:         http.StatusConflict,
	CodeNotFound:            http.StatusNotFound,
	CodeInternal:            http.StatusInternalServerError,
}

type APIError struct {
	Code      ErrorCode          `json:"code"`
	Message   string             `json:"message"`
	Details   []ValidationDetail `json:"details,omitempty"`
	RequestID string             `json:"request_id,omitempty"`
	Retryable bool               `json:"retryable"`
}

type ValidationDetail struct {
	Field   string `json:"field"`
	Message string `json:"message"`
}

type errorEnvelope struct {
	Error APIError `json:"error"`
}

// ErrorLogDetail is everything WriteError captures synchronously (while the
// request is still live) for the sink to persist asynchronously — see
// SetErrorSink's doc comment on why this handoff exists at all. Every field
// here is a plain value copied out of the request, never the live
// *http.Request itself, so the detached goroutine that actually writes it
// can safely outlive the request.
type ErrorLogDetail struct {
	RequestID            string
	StatusCode           int
	Code                 string
	Message              string
	Method               string
	Path                 string
	QueryParams          string
	RequestBody          []byte // already redacted by RedactJSON before this point
	IP                   string
	UserAgent            string
	TenantID             *string
	ActorUserID          *string
	ActorPlatformAdminID *string
	StackTrace           string // non-empty only for a recovered panic
}

// errorSink, when set via SetErrorSink, receives full debug-level detail for
// EVERY error response this API ever writes — not just CodeInternal — the
// one durable, queryable record of what actually happened beyond
// stdout/docker-logs (see the platform admin error log screen). A plain
// function var, not an interface, since there is exactly one implementation
// and it must never block or panic the request that triggered it.
var errorSink func(detail ErrorLogDetail)

// SetErrorSink installs the function that persists error details. Called
// once at startup from main.go; nil (the default) disables persistence
// entirely, which is fine for tests.
func SetErrorSink(sink func(detail ErrorLogDetail)) {
	errorSink = sink
}

// WriteError writes the standardized error envelope and persists full
// debug-level detail for it via errorSink — every error this API returns,
// not only CodeInternal. Internal error details are never included in
// `message` for CodeInternal in the client-facing response (that's logged
// server-side only, and the client sees a generic, safe message instead) —
// everything else (validation/not-found/etc.) already has a safe message by
// construction, so it's returned to the client as-is.
func WriteError(w http.ResponseWriter, r *http.Request, code ErrorCode, message string, details ...ValidationDetail) {
	writeErrorDetailed(w, r, code, message, "", details...)
}

// writeErrorWithPanic is middleware.Recoverer's exclusive entry point — the
// only call site that has an actual stack trace to attach, since every
// other error path is a normal `return`, not a recovered panic.
func WriteErrorWithPanic(w http.ResponseWriter, r *http.Request, panicValue interface{}, stack string) {
	writeErrorDetailed(w, r, CodeInternal, fmt.Sprintf("panic: %v", panicValue), stack)
}

func writeErrorDetailed(w http.ResponseWriter, r *http.Request, code ErrorCode, message, stack string, details ...ValidationDetail) {
	status, ok := httpStatusByCode[code]
	if !ok {
		status = http.StatusInternalServerError
	}
	requestID := reqctx.RequestID(r.Context())
	meta := reqctx.GetRequestMeta(r.Context())
	persistedMessage := message

	if code == CodeInternal {
		// The real cause never reaches the client (only a generic, safe
		// message does) but must not be lost entirely — log it here, the one
		// place every CodeInternal response passes through, rather than
		// requiring every call site to remember to log before calling this.
		slog.Error("internal server error", "request_id", requestID, "detail", message)
		message = "An internal error occurred. Please retry or contact support with the request ID."
	}

	if errorSink != nil {
		detail := ErrorLogDetail{
			RequestID:   requestID,
			StatusCode:  status,
			Code:        string(code),
			Message:     persistedMessage,
			Method:      r.Method,
			Path:        r.URL.Path,
			QueryParams: r.URL.RawQuery,
			RequestBody: reqctx.GetRequestBody(r.Context()),
			IP:          meta.IP,
			UserAgent:   meta.UserAgent,
			StackTrace:  stack,
		}
		if claims, ok := reqctx.Claims(r.Context()); ok {
			userID := claims.UserID.String()
			if claims.IsPlatform {
				detail.ActorPlatformAdminID = &userID
			} else {
				tenantID := claims.TenantID.String()
				detail.TenantID = &tenantID
				detail.ActorUserID = &userID
			}
		}
		errorSink(detail)
	}

	retryable := code == CodeInternal || code == CodePaymentUnknown
	writeJSON(w, status, errorEnvelope{Error: APIError{
		Code:      code,
		Message:   message,
		Details:   details,
		RequestID: requestID,
		Retryable: retryable,
	}})
}

func WriteJSON(w http.ResponseWriter, status int, payload interface{}) {
	writeJSON(w, status, payload)
}

func writeJSON(w http.ResponseWriter, status int, payload interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}
