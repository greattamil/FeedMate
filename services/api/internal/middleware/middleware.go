// Package middleware provides cross-cutting HTTP concerns: request correlation
// IDs, panic recovery, and JWT-based authentication that establishes the trusted
// tenant/user/device identity used by every downstream handler.
package middleware

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"runtime/debug"
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

// CaptureRequestMeta records the caller-identifying detail (IP, user agent)
// every audit-log entry and error-log row should carry, once per request —
// see reqctx.RequestMeta's doc comment for why this exists instead of
// threading IP/UA through every individual call site's own parameters.
// Must run after RequestID (order doesn't matter relative to it, just
// needs to run before anything that reads reqctx.GetRequestMeta).
func CaptureRequestMeta(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := r.RemoteAddr
		if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
			// The first address in a comma-separated chain is the original
			// client — everything after it was added by intermediate
			// proxies (this API sits behind Caddy in production).
			ip = strings.TrimSpace(strings.Split(fwd, ",")[0])
		} else if host, _, err := net.SplitHostPort(ip); err == nil {
			ip = host
		}
		meta := reqctx.RequestMeta{IP: ip, UserAgent: r.Header.Get("User-Agent")}
		ctx := reqctx.WithRequestMeta(r.Context(), meta)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// maxReadableBodySize is a hard safety cap on how much of a request body
// this middleware will ever read into memory at all — every real request
// this API handles is a small JSON payload (there are no file-upload
// endpoints), so this is generous headroom, not a practical limit. Above
// it, the body is left completely untouched (streamed straight to the
// handler as normal) and simply isn't available for error-log capture —
// correctness of request handling always wins over logging.
const maxReadableBodySize = 10 * 1024 * 1024

// BufferRequestBody reads and restores r.Body so a handler's own
// json.Decode works exactly as before, while stashing a redacted copy in
// context for WriteError to persist on error — handlers have usually
// already fully consumed r.Body by the time an error is written, so
// without this, error logging would have nothing to show for the request
// that failed. The redacted copy itself is further size-capped by
// httpapi.RedactJSON — this middleware's own cap exists only to bound
// memory use while reading, not to decide what's loggable.
func BufferRequestBody(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Body == nil || r.ContentLength == 0 {
			next.ServeHTTP(w, r)
			return
		}
		if r.ContentLength > maxReadableBodySize {
			next.ServeHTTP(w, r)
			return
		}
		// io.LimitReader is the real backstop (ContentLength can be -1 for
		// chunked requests, in which case the check above never fires).
		raw, err := io.ReadAll(io.LimitReader(r.Body, maxReadableBodySize))
		if err != nil {
			next.ServeHTTP(w, r)
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(raw))
		ctx := reqctx.WithRequestBody(r.Context(), httpapi.RedactJSON(raw))
		next.ServeHTTP(w, r.WithContext(ctx))
	})
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
// crashing the process or leaking a stack trace to the client — the real
// panic value and a full stack trace are still captured, just routed only
// to the error-log row (via WriteErrorWithPanic), never to the client.
func Recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				stack := string(debug.Stack())
				slog.Error("panic recovered", "request_id", RequestIDFromContext(r.Context()), "panic", rec)
				httpapi.WriteErrorWithPanic(w, r, rec, stack)
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
			authHeader := r.Header.Get("Authorization")
			if !strings.HasPrefix(authHeader, "Bearer ") {
				httpapi.WriteError(w, r, httpapi.CodeUnauthorized, "missing bearer token")
				return
			}
			token := strings.TrimPrefix(authHeader, "Bearer ")
			claims, err := auth.ParseAccessToken(signingKey, token)
			if err != nil {
				httpapi.WriteError(w, r, httpapi.CodeUnauthorized, "invalid or expired token")
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
		claims, ok := ClaimsFromContext(r.Context())
		if !ok || !claims.IsPlatform {
			httpapi.WriteError(w, r, httpapi.CodeForbidden, "platform admin access required")
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
			claims, ok := ClaimsFromContext(r.Context())
			if !ok {
				httpapi.WriteError(w, r, httpapi.CodeUnauthorized, "authentication required")
				return
			}
			for _, p := range claims.Permissions {
				if p == code {
					next.ServeHTTP(w, r)
					return
				}
			}
			httpapi.WriteError(w, r, httpapi.CodeForbidden, "missing required permission: "+code)
		})
	}
}
