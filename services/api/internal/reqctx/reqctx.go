// Package reqctx holds the request-scoped context helpers shared by the
// middleware and httpapi packages, kept separate to avoid an import cycle
// between them (both need the request ID; middleware also needs to write
// error responses using it).
package reqctx

import "context"

type key int

const requestIDKey key = 0

func WithRequestID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, requestIDKey, id)
}

func RequestID(ctx context.Context) string {
	if v, ok := ctx.Value(requestIDKey).(string); ok {
		return v
	}
	return ""
}
