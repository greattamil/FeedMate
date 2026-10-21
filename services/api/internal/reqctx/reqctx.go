// Package reqctx holds the request-scoped context helpers shared by the
// middleware and httpapi packages, kept separate to avoid an import cycle
// between them (both need the request ID; middleware also needs to write
// error responses using it).
package reqctx

import (
	"context"

	"github.com/google/uuid"

	"github.com/andipatti/feedmate/services/api/internal/auth"
)

type key int

const (
	requestIDKey key = iota
	claimsKey
	requestMetaKey
	requestBodyKey
)

// RequestMeta is the caller-identifying detail every audit-log entry and
// error-log row should carry — captured once per request by
// middleware.CaptureRequestMeta, read by both auditlog call sites and
// WriteError, so no individual call site needs to thread IP/user-agent
// through its own function signature.
type RequestMeta struct {
	IP        string
	UserAgent string
}

func WithRequestMeta(ctx context.Context, meta RequestMeta) context.Context {
	return context.WithValue(ctx, requestMetaKey, meta)
}

func GetRequestMeta(ctx context.Context) RequestMeta {
	if v, ok := ctx.Value(requestMetaKey).(RequestMeta); ok {
		return v
	}
	return RequestMeta{}
}

// WithRequestBody stashes the raw (already redacted) request body captured
// by middleware.BufferRequestBody, so WriteError can persist it on error
// without needing to re-read r.Body itself (which handlers have usually
// already consumed by the time an error is written).
func WithRequestBody(ctx context.Context, redactedBody []byte) context.Context {
	return context.WithValue(ctx, requestBodyKey, redactedBody)
}

func GetRequestBody(ctx context.Context) []byte {
	if v, ok := ctx.Value(requestBodyKey).([]byte); ok {
		return v
	}
	return nil
}

func WithRequestID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, requestIDKey, id)
}

func RequestID(ctx context.Context) string {
	if v, ok := ctx.Value(requestIDKey).(string); ok {
		return v
	}
	return ""
}

// WithClaims stores the verified access-token claims on the context. Only the
// auth middleware, which has already validated the token signature and
// expiry, may call this.
func WithClaims(ctx context.Context, claims *auth.AccessClaims) context.Context {
	return context.WithValue(ctx, claimsKey, claims)
}

// Claims retrieves the trusted claims set by the auth middleware. Handlers
// use this — never a client-supplied tenant/user header — as the sole source
// of tenant/user/device identity for a request.
func Claims(ctx context.Context) (*auth.AccessClaims, bool) {
	claims, ok := ctx.Value(claimsKey).(*auth.AccessClaims)
	return claims, ok
}

// AuditFields is the ready-to-use (requestID, ip, userAgent) tuple every
// audit_logs INSERT statement now passes for its request_id/ip_address/
// user_agent columns — these have existed in the schema since the table
// was created but, before this, were never populated by any of the ~20
// call sites that write to it. requestID is nil if the current request's
// ID isn't a valid UUID (e.g. a client-supplied, non-UUID X-Request-ID
// header — see middleware.RequestID's fallback).
func AuditFields(ctx context.Context) (requestID *uuid.UUID, ip, userAgent *string) {
	if id, err := uuid.Parse(RequestID(ctx)); err == nil {
		requestID = &id
	}
	meta := GetRequestMeta(ctx)
	if meta.IP != "" {
		ip = &meta.IP
	}
	if meta.UserAgent != "" {
		userAgent = &meta.UserAgent
	}
	return
}
