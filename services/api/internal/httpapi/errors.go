package httpapi

import (
	"encoding/json"
	"net/http"
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
	Code      ErrorCode         `json:"code"`
	Message   string            `json:"message"`
	Details   []ValidationDetail `json:"details,omitempty"`
	RequestID string            `json:"request_id,omitempty"`
	Retryable bool              `json:"retryable"`
}

type ValidationDetail struct {
	Field   string `json:"field"`
	Message string `json:"message"`
}

type errorEnvelope struct {
	Error APIError `json:"error"`
}

// WriteError writes the standardized error envelope. Internal error details are
// never included in `message` for CodeInternal — that is logged server-side only
// and the client sees a generic, safe message.
func WriteError(w http.ResponseWriter, requestID string, code ErrorCode, message string, details ...ValidationDetail) {
	status, ok := httpStatusByCode[code]
	if !ok {
		status = http.StatusInternalServerError
	}
	if code == CodeInternal {
		message = "An internal error occurred. Please retry or contact support with the request ID."
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
