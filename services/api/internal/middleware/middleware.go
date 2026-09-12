// Package middleware provides cross-cutting HTTP concerns: request correlation
// IDs, panic recovery, and JWT-based authentication that establishes the trusted
// tenant/user/device identity used by every downstream handler.
package middleware

import (
	"context"
	"log/slog"
	"net/http"
	"strings"

	"github.com/google/uuid"

	"github.com/andipatti/feedmate/services/api/internal/auth"
	"github.com/andipatti/feedmate/services/api/internal/httpapi"
	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

type ctxKey int

const (
	ctxKeyClaims ctxKey = iota
)

func RequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get("X-Request-ID")
		if id == "" {
			id = uuid.NewString()
		}
		w.Header().Set("X-Request-ID", id)
		ctx := reqctx.WithRequestID(r.Context(), id)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// RequestIDFromContext is re-exported for handler code that already imports
// this package; it delegates to the shared reqctx package.
func RequestIDFromContext(ctx context.Context) string {
	return reqctx.RequestID(ctx)
}

// Recoverer converts a panic into a safe INTERNAL_ERROR response instead of
// crashing the process or leaking a stack trace to the client.
func Recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				reqID := RequestIDFromContext(r.Context())
				slog.Error("panic recovered", "request_id", reqID, "panic", rec)
				httpapi.WriteError(w, reqID, httpapi.CodeInternal, "internal error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// RequireAuth parses and verifies the bearer access token and injects the
// trusted claims into the request context. It performs no database lookups —
// tenant/permission enforcement happens downstream using these verified claims.
func RequireAuth(signingKey string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			reqID := RequestIDFromContext(r.Context())
			authHeader := r.Header.Get("Authorization")
			if !strings.HasPrefix(authHeader, "Bearer ") {
				httpapi.WriteError(w, reqID, httpapi.CodeUnauthorized, "missing bearer token")
				return
			}
			token := strings.TrimPrefix(authHeader, "Bearer ")
			claims, err := auth.ParseAccessToken(signingKey, token)
			if err != nil {
				httpapi.WriteError(w, reqID, httpapi.CodeUnauthorized, "invalid or expired token")
				return
			}
			ctx := context.WithValue(r.Context(), ctxKeyClaims, claims)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

func ClaimsFromContext(ctx context.Context) (*auth.AccessClaims, bool) {
	claims, ok := ctx.Value(ctxKeyClaims).(*auth.AccessClaims)
	return claims, ok
}

// RequirePermission enforces that the authenticated user's token carries the
// given permission code. This is the application-layer RBAC check that sits
// alongside — never instead of — PostgreSQL RLS.
func RequirePermission(code string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			reqID := RequestIDFromContext(r.Context())
			claims, ok := ClaimsFromContext(r.Context())
			if !ok {
				httpapi.WriteError(w, reqID, httpapi.CodeUnauthorized, "authentication required")
				return
			}
			for _, p := range claims.Permissions {
				if p == code {
					next.ServeHTTP(w, r)
					return
				}
			}
			httpapi.WriteError(w, reqID, httpapi.CodeForbidden, "missing required permission: "+code)
		})
	}
}
