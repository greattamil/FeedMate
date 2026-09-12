package payment

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

var ErrNotFound = errors.New("not found")

type Intent struct {
	ID                     uuid.UUID
	TenantID               uuid.UUID
	InvoiceID              *uuid.UUID
	CustomerID             *uuid.UUID
	Provider               string
	ProviderOrderReference string
	Amount                 decimal.Decimal
	Status                 string
	ExpiresAt              *time.Time
	IdempotencyKey         string
}

func InsertIntent(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, in *Intent) error {
	row := tx.QueryRow(ctx, `
		INSERT INTO payment_intents (tenant_id, invoice_id, customer_id, provider, provider_order_reference, amount, status, expires_at, idempotency_key)
		VALUES ($1,$2,$3,$4,$5,$6,'PENDING',$7,$8)
		ON CONFLICT (tenant_id, idempotency_key) DO UPDATE SET provider = payment_intents.provider
		RETURNING id, status
	`, tenantID, in.InvoiceID, in.CustomerID, in.Provider, in.ProviderOrderReference, in.Amount, in.ExpiresAt, in.IdempotencyKey)
	return row.Scan(&in.ID, &in.Status)
}

// FindIntentByOrderReference performs the cross-tenant lookup a webhook must
// do before it knows which tenant's data to touch — the provider only gives
// us its own order reference, not our tenant_id. This is a narrowly scoped,
// read-only exception and must run under admin mode; every subsequent write
// happens under the resolved tenant's own RLS context.
func FindIntentByOrderReference(ctx context.Context, tx pgx.Tx, provider, orderReference string) (*Intent, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, tenant_id, invoice_id, customer_id, provider, provider_order_reference, amount, status, expires_at, idempotency_key
		FROM payment_intents WHERE provider = $1 AND provider_order_reference = $2
	`, provider, orderReference)
	var in Intent
	if err := row.Scan(&in.ID, &in.TenantID, &in.InvoiceID, &in.CustomerID, &in.Provider, &in.ProviderOrderReference,
		&in.Amount, &in.Status, &in.ExpiresAt, &in.IdempotencyKey); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &in, nil
}

func UpdateIntentStatus(ctx context.Context, tx pgx.Tx, intentID uuid.UUID, status string) error {
	_, err := tx.Exec(ctx, `UPDATE payment_intents SET status = $2, updated_at = now() WHERE id = $1`, intentID, status)
	return err
}

func GetIntentByID(ctx context.Context, tx pgx.Tx, id uuid.UUID) (*Intent, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, tenant_id, invoice_id, customer_id, provider, provider_order_reference, amount, status, expires_at, idempotency_key
		FROM payment_intents WHERE id = $1
	`, id)
	var in Intent
	if err := row.Scan(&in.ID, &in.TenantID, &in.InvoiceID, &in.CustomerID, &in.Provider, &in.ProviderOrderReference,
		&in.Amount, &in.Status, &in.ExpiresAt, &in.IdempotencyKey); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &in, nil
}

// InsertWebhookEventIfNew is the idempotency gate for webhook processing: the
// unique(provider, event_id) constraint means a redelivered event can only
// ever be inserted once. Returns (id, true) for a newly recorded event, or
// (uuid.Nil, false) if this event_id was already processed — callers must
// stop immediately in the false case and produce no further side effects
// (PRD 11.1 / A11: duplicate payment webhooks must have no financial side
// effects).
func InsertWebhookEventIfNew(ctx context.Context, tx pgx.Tx, provider, eventID, eventType, payloadHash string, payload []byte, signatureVerified bool) (uuid.UUID, bool, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO payment_webhook_events (provider, event_id, event_type, payload_hash, payload, signature_verified, processing_status)
		VALUES ($1,$2,$3,$4,$5,$6,'RECEIVED')
		ON CONFLICT (provider, event_id) DO NOTHING
		RETURNING id
	`, provider, eventID, eventType, payloadHash, payload, signatureVerified).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, false, nil
	}
	if err != nil {
		return uuid.Nil, false, err
	}
	return id, true, nil
}

func MarkWebhookEventProcessed(ctx context.Context, tx pgx.Tx, eventRowID uuid.UUID, tenantID *uuid.UUID, status string, errorCode *string) error {
	_, err := tx.Exec(ctx, `
		UPDATE payment_webhook_events SET processing_status = $2, processed_at = now(), tenant_id = COALESCE($3, tenant_id), error_code = $4
		WHERE id = $1
	`, eventRowID, status, tenantID, errorCode)
	return err
}

type PaymentRecord struct {
	ID                uuid.UUID
	PaymentIntentID    uuid.UUID
	Provider          string
	ProviderPaymentID string
	Method            string
	Amount            decimal.Decimal
	Status            string
}

// InsertPaymentIfNew provides idempotency at the (provider, provider_payment_id)
// level as a second line of defense beyond the webhook-event idempotency
// gate: even if the same underlying payment were ever reported by two
// different event IDs, this unique constraint still prevents a duplicate
// payment record and duplicate financial effects.
func InsertPaymentIfNew(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, p *PaymentRecord) (bool, error) {
	row := tx.QueryRow(ctx, `
		INSERT INTO payments (tenant_id, payment_intent_id, provider, provider_payment_id, method, amount, status, received_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7, now())
		ON CONFLICT (provider, provider_payment_id) DO NOTHING
		RETURNING id
	`, tenantID, p.PaymentIntentID, p.Provider, p.ProviderPaymentID, p.Method, p.Amount, p.Status)
	if err := row.Scan(&p.ID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}
