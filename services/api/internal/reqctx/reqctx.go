// Package reqctx holds the request-scoped context helpers shared by the
// middleware and httpapi packages, kept separate to avoid an import cycle
// between them (both need the request ID; middleware also needs to write
// error responses using it).
package reqctx

import (
	"context"

	"github.com/andipatti/feedmate/services/api/internal/auth"
)

type key int

const (
	requestIDKey key = iota
	claimsKey
)

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
