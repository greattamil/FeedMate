package paymentprovider

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"
)

// SandboxProvider is a deterministic, clearly-non-production implementation
// of Provider used for development and testing. It signs webhook payloads
// with HMAC-SHA256 the same way most real UPI gateways do (a shared secret
// signing the raw request body), so the signature-verification code path is
// exercised for real rather than stubbed out. It must never be selected in
// an environment configured as production (see config.AppEnv).
type SandboxProvider struct {
	webhookSecret string
}

func NewSandboxProvider(webhookSecret string) *SandboxProvider {
	return &SandboxProvider{webhookSecret: webhookSecret}
}

func (p *SandboxProvider) Name() string { return "SANDBOX" }

func (p *SandboxProvider) CreateIntent(ctx context.Context, req CreateIntentRequest) (*IntentResponse, error) {
	orderRef := "sandbox_order_" + uuid.NewString()
	qr := fmt.Sprintf("upi://pay?pa=shop@sandbox&am=%s&cu=%s&tr=%s", req.Amount.StringFixed(2), req.Currency, orderRef)
	return &IntentResponse{
		ProviderOrderReference: orderRef,
		QRPayload:              qr,
		ExpiresAt:              time.Now().Add(15 * time.Minute),
	}, nil
}

// SandboxWebhookPayload is the JSON shape this sandbox's simulated webhook
// sender (e.g. a test script or the reconciliation test harness) posts.
type SandboxWebhookPayload struct {
	EventID           string `json:"event_id"`
	EventType         string `json:"event_type"`
	OrderReference    string `json:"order_reference"`
	ProviderPaymentID string `json:"provider_payment_id"`
	Status            string `json:"status"`
	AmountPaise       int64  `json:"amount_paise"`
}

func (p *SandboxProvider) SignPayload(payload []byte) string {
	mac := hmac.New(sha256.New, []byte(p.webhookSecret))
	mac.Write(payload)
	return hex.EncodeToString(mac.Sum(nil))
}

func (p *SandboxProvider) VerifyWebhookSignature(payload []byte, signatureHeader string) bool {
	expected := p.SignPayload(payload)
	return hmac.Equal([]byte(expected), []byte(signatureHeader))
}

func (p *SandboxProvider) ParseWebhookEvent(payload []byte) (*WebhookEvent, error) {
	var raw SandboxWebhookPayload
	if err := json.Unmarshal(payload, &raw); err != nil {
		return nil, fmt.Errorf("parse sandbox webhook payload: %w", err)
	}
	return &WebhookEvent{
		EventID:                raw.EventID,
		EventType:              raw.EventType,
		ProviderOrderReference: raw.OrderReference,
		ProviderPaymentID:      raw.ProviderPaymentID,
		Status:                 raw.Status,
		Amount:                 decimal.NewFromInt(raw.AmountPaise).Div(decimal.NewFromInt(100)),
	}, nil
}
