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

// CORS lets a browser-hosted client (the Flutter web build, served from a
// different origin/port than this API during local development) call it —
// without this, every fetch from that origin is blocked by the browser
// before it ever reaches Go. Auth here is always a Bearer token, never a
// cookie, so credentialed CORS is unnecessary; reflecting whatever Origin
// the browser sends keeps local dev working without hardcoding Flutter's
// ephemeral dev-server port. A production deployment serving a real public
// web frontend should tighten this to an explicit origin allow-list.
func CORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if origin := r.Header.Get("Origin"); origin != "" {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Request-ID")
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
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
			ctx := reqctx.WithClaims(r.Context(), claims)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// ClaimsFromContext is re-exported for handler code that already imports this
// package; it delegates to the shared reqctx package.
func ClaimsFromContext(ctx context.Context) (*auth.AccessClaims, bool) {
	return reqctx.Claims(ctx)
}

// RequirePlatform enforces that the authenticated token is a platform-admin
// session (see auth.IssuePlatformAccessToken), never an ordinary tenant
// user's token — checked on the IsPlatform claim itself, not just a
// permission string, since IsPlatform can only ever be set by the platform
// login/refresh path.
func RequirePlatform(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reqID := RequestIDFromContext(r.Context())
		claims, ok := ClaimsFromContext(r.Context())
		if !ok || !claims.IsPlatform {
			httpapi.WriteError(w, reqID, httpapi.CodeForbidden, "platform admin access required")
			return
		}
		next.ServeHTTP(w, r)
	})
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
