package config

import "testing"

// Cloud Run injects PORT at runtime and requires the container to bind to
// it regardless of anything baked into the image; HTTP_ADDR must still work
// for every other deployment target (docker-compose, local dev) where PORT
// is never set. See resolveHTTPAddr's doc comment.
func TestResolveHTTPAddr_PrefersPortOverHTTPAddr(t *testing.T) {
	t.Setenv("PORT", "8080")
	t.Setenv("HTTP_ADDR", ":9999")

	if got := resolveHTTPAddr(); got != ":8080" {
		t.Fatalf("expected PORT to take priority, got %q", got)
	}
}

func TestResolveHTTPAddr_FallsBackToHTTPAddrWhenPortUnset(t *testing.T) {
	t.Setenv("HTTP_ADDR", ":8081")

	if got := resolveHTTPAddr(); got != ":8081" {
		t.Fatalf("expected HTTP_ADDR fallback, got %q", got)
	}
}

func TestResolveHTTPAddr_DefaultsWhenNeitherSet(t *testing.T) {
	if got := resolveHTTPAddr(); got != ":8080" {
		t.Fatalf("expected default :8080, got %q", got)
	}
}
