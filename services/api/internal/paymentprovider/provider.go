// Package paymentprovider defines the provider-agnostic interface the
// payment domain depends on, so the system is never wired to one specific
// UPI/payment gateway (PRD 11.1: "use provider abstraction so the system can
// support multiple gateways/collect mechanisms"). Production credentials for
// a real gateway (Razorpay, Cashfree, PhonePe, etc.) are not available in
// this environment; SandboxProvider implements the same interface with
// deterministic, clearly-non-production behavior so the rest of the system
// (intent creation, webhook signature verification, idempotent processing,
// reconciliation) is fully implemented and testable end to end. Swapping in
// a real provider means writing one more implementation of this interface —
// no other code changes.
package paymentprovider

import (
	"context"
	"time"

	"github.com/shopspring/decimal"
)

type CreateIntentRequest struct {
	Amount      decimal.Decimal
	Currency    string
	ReferenceID string // our idempotency key, passed through to the provider where supported
}

type IntentResponse struct {
	ProviderOrderReference string
	QRPayload              string // e.g. a UPI deep link or QR string the POS renders
	ExpiresAt              time.Time
}

// WebhookEvent is the provider-agnostic shape a Provider must normalize its
// raw webhook payload into. EventID must be stable and unique per event so
// duplicate webhook deliveries can be detected before any side effect runs.
type WebhookEvent struct {
	EventID                string
	EventType              string
	ProviderOrderReference string
	ProviderPaymentID      string
	Status                 string // SUCCESS, FAILED, EXPIRED
	Amount                 decimal.Decimal
}

type Provider interface {
	Name() string
	CreateIntent(ctx context.Context, req CreateIntentRequest) (*IntentResponse, error)

	// VerifyWebhookSignature must return false for any payload/signature pair
	// that does not authenticate — webhook processing must never trust an
	// unverified payload (PRD 11.1).
	VerifyWebhookSignature(payload []byte, signatureHeader string) bool
	ParseWebhookEvent(payload []byte) (*WebhookEvent, error)
}
