package payment

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/accounting"
	"github.com/andipatti/feedmate/services/api/internal/domain/customer"
	"github.com/andipatti/feedmate/services/api/internal/domain/supplier"
	"github.com/andipatti/feedmate/services/api/internal/paymentprovider"
)

var (
	ErrValidation         = errors.New("validation error")
	ErrInvalidSignature   = errors.New("webhook signature verification failed")
	ErrIntentNotFound     = errors.New("payment intent not found for this order reference")
	ErrAmountMismatch     = errors.New("webhook amount does not match the payment intent amount")
)

type Service struct {
	db       *dbctx.DB
	provider paymentprovider.Provider
}

func NewService(db *dbctx.DB, provider paymentprovider.Provider) *Service {
	return &Service{db: db, provider: provider}
}

type CreateReceiptIntentRequest struct {
	CustomerID uuid.UUID
	Amount     decimal.Decimal
	// IdempotencyKey lets the POS/collection app safely retry a request
	// (e.g. after a network timeout) without generating a second QR/intent
	// for the same logical collection attempt.
	IdempotencyKey string
}

type CreateReceiptIntentResult struct {
	IntentID     uuid.UUID
	QRPayload    string
	Status       string
}

// CreateReceiptIntent starts a UPI collection against a customer's Khata
// balance (PRD 10.2/10.4: receipts and collection reminders may generate a
// UPI payment link "only through a configured payment/collection
// mechanism" — never an ad hoc, unverified amount). The customer's ledger is
// NOT touched here: it is only updated once the provider's webhook confirms
// success (see ProcessWebhook) — the POS/app must never mark a receipt
// collected just because the customer claims to have paid.
func (s *Service) CreateReceiptIntent(ctx context.Context, tenantID uuid.UUID, req CreateReceiptIntentRequest) (*CreateReceiptIntentResult, error) {
	if req.Amount.LessThanOrEqual(decimal.Zero) {
		return nil, fmt.Errorf("%w: amount must be positive", ErrValidation)
	}
	if req.IdempotencyKey == "" {
		return nil, fmt.Errorf("%w: idempotency_key is required", ErrValidation)
	}

	var result CreateReceiptIntentResult
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		if _, err := customer.GetByID(ctx, tx, req.CustomerID); err != nil {
			return fmt.Errorf("load customer: %w", err)
		}

		providerResp, err := s.provider.CreateIntent(ctx, paymentprovider.CreateIntentRequest{
			Amount: req.Amount, Currency: "INR", ReferenceID: req.IdempotencyKey,
		})
		if err != nil {
			return fmt.Errorf("create provider intent: %w", err)
		}

		intent := &Intent{
			CustomerID: &req.CustomerID, Provider: s.provider.Name(),
			ProviderOrderReference: providerResp.ProviderOrderReference, Amount: req.Amount,
			ExpiresAt: &providerResp.ExpiresAt, IdempotencyKey: req.IdempotencyKey,
		}
		if err := InsertIntent(ctx, tx, tenantID, intent); err != nil {
			return fmt.Errorf("insert payment intent: %w", err)
		}

		result = CreateReceiptIntentResult{IntentID: intent.ID, QRPayload: providerResp.QRPayload, Status: intent.Status}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

type RecordManualReceiptRequest struct {
	CustomerID     uuid.UUID
	Amount         decimal.Decimal
	Method         string // CASH, BANK, or OTHER — never UPI (that must go through CreateReceiptIntent/ProcessWebhook)
	Reference      string
	IdempotencyKey string
}

type RecordManualReceiptResult struct {
	PaymentID uuid.UUID
	Duplicate bool
}

var manualReceiptMethods = map[string]bool{"CASH": true, "BANK": true, "OTHER": true}

// RecordManualReceipt posts a receipt collected in person — there is no
// provider to confirm it, so unlike a UPI receipt (see ProcessWebhook) the
// cashier's own authenticated action is the confirmation, the same trust
// boundary already accepted for a CASH tender at POS checkout. Idempotent
// on IdempotencyKey: a retried request (e.g. after a network timeout on the
// response) returns the original result rather than posting twice.
func (s *Service) RecordManualReceipt(ctx context.Context, tenantID uuid.UUID, req RecordManualReceiptRequest) (*RecordManualReceiptResult, error) {
	if req.Amount.LessThanOrEqual(decimal.Zero) {
		return nil, fmt.Errorf("%w: amount must be positive", ErrValidation)
	}
	if !manualReceiptMethods[req.Method] {
		return nil, fmt.Errorf("%w: method must be one of CASH, BANK, OTHER", ErrValidation)
	}
	if req.IdempotencyKey == "" {
		return nil, fmt.Errorf("%w: idempotency_key is required", ErrValidation)
	}

	var result RecordManualReceiptResult
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		if _, err := customer.GetByID(ctx, tx, req.CustomerID); err != nil {
			return fmt.Errorf("load customer: %w", err)
		}

		p := &ManualPayment{
			Method: req.Method, Amount: req.Amount,
			IdempotencyKey: req.IdempotencyKey, Reference: req.Reference,
		}
		created, err := InsertManualPaymentIfNew(ctx, tx, tenantID, p)
		if err != nil {
			return fmt.Errorf("insert manual payment: %w", err)
		}
		if !created {
			existing, err := FindManualPaymentByIdempotencyKey(ctx, tx, tenantID, req.IdempotencyKey)
			if err != nil {
				return fmt.Errorf("resolve duplicate manual payment: %w", err)
			}
			result = RecordManualReceiptResult{PaymentID: existing.ID, Duplicate: true}
			return nil
		}

		if err := postManualReceiptLedgerAndJournal(ctx, tx, tenantID, req.CustomerID, p.ID, req.Method, req.Amount); err != nil {
			return fmt.Errorf("post receipt ledger/journal: %w", err)
		}
		result = RecordManualReceiptResult{PaymentID: p.ID, Duplicate: false}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

type RecordSupplierPaymentRequest struct {
	SupplierID     uuid.UUID
	Amount         decimal.Decimal
	Method         string // CASH, BANK, or OTHER
	Reference      string
	IdempotencyKey string
}

type RecordSupplierPaymentResult struct {
	PaymentID uuid.UUID
	Duplicate bool
}

// RecordSupplierPayment is RecordManualReceipt's mirror image on the payable
// side: it decreases what the shop owes a supplier (a debit to the supplier
// ledger, opposite of a customer receipt's credit — see
// supplier.PostLedgerEntry) instead of increasing it. Same idempotency and
// trust-boundary reasoning applies: paying a supplier cash in person has no
// provider to confirm it, so the authenticated staff member's own action is
// the confirmation.
func (s *Service) RecordSupplierPayment(ctx context.Context, tenantID uuid.UUID, req RecordSupplierPaymentRequest) (*RecordSupplierPaymentResult, error) {
	if req.Amount.LessThanOrEqual(decimal.Zero) {
		return nil, fmt.Errorf("%w: amount must be positive", ErrValidation)
	}
	if !manualReceiptMethods[req.Method] {
		return nil, fmt.Errorf("%w: method must be one of CASH, BANK, OTHER", ErrValidation)
	}
	if req.IdempotencyKey == "" {
		return nil, fmt.Errorf("%w: idempotency_key is required", ErrValidation)
	}

	var result RecordSupplierPaymentResult
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		if _, err := supplier.GetByID(ctx, tx, req.SupplierID); err != nil {
			return fmt.Errorf("load supplier: %w", err)
		}

		p := &ManualPayment{
			Method: req.Method, Amount: req.Amount,
			IdempotencyKey: req.IdempotencyKey, Reference: req.Reference,
		}
		created, err := InsertManualPaymentIfNew(ctx, tx, tenantID, p)
		if err != nil {
			return fmt.Errorf("insert manual payment: %w", err)
		}
		if !created {
			existing, err := FindManualPaymentByIdempotencyKey(ctx, tx, tenantID, req.IdempotencyKey)
			if err != nil {
				return fmt.Errorf("resolve duplicate manual payment: %w", err)
			}
			result = RecordSupplierPaymentResult{PaymentID: existing.ID, Duplicate: true}
			return nil
		}

		if err := postSupplierPaymentLedgerAndJournal(ctx, tx, tenantID, req.SupplierID, p.ID, req.Method, req.Amount); err != nil {
			return fmt.Errorf("post payment ledger/journal: %w", err)
		}
		result = RecordSupplierPaymentResult{PaymentID: p.ID, Duplicate: false}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

func (s *Service) GetIntentStatus(ctx context.Context, tenantID, intentID uuid.UUID) (string, error) {
	var status string
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		intent, err := GetIntentByID(ctx, tx, intentID)
		if err != nil {
			return err
		}
		status = intent.Status
		return nil
	})
	return status, err
}

// ProcessWebhook is the sole authoritative path by which a payment is ever
// marked successful (PRD 11.1: "do not mark an invoice/receipt paid solely
// because a client says payment succeeded"). It:
//  1. verifies the provider's signature over the raw payload — an
//     unverified payload is rejected outright, with no side effects;
//  2. gates on (provider, event_id) uniqueness so a redelivered webhook has
//     zero financial side effects the second time;
//  3. resolves which tenant the payment belongs to (the one narrow,
//     read-only cross-tenant lookup this system performs, since the
//     provider has no concept of our tenants) and does all subsequent
//     writes under that tenant's own RLS context;
//  4. validates the paid amount matches the intent's expected amount before
//     posting anything;
//  5. posts the customer ledger credit and a balanced accounting journal
//     atomically with the payment/intent status update.
func (s *Service) ProcessWebhook(ctx context.Context, rawPayload []byte, signatureHeader string) error {
	if !s.provider.VerifyWebhookSignature(rawPayload, signatureHeader) {
		return ErrInvalidSignature
	}

	event, err := s.provider.ParseWebhookEvent(rawPayload)
	if err != nil {
		return fmt.Errorf("parse webhook event: %w", err)
	}
	if event.EventID == "" {
		return fmt.Errorf("%w: webhook event_id is required", ErrValidation)
	}

	sum := sha256.Sum256(rawPayload)
	payloadHash := hex.EncodeToString(sum[:])

	var (
		eventRowID uuid.UUID
		isNew      bool
	)
	err = s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		eventRowID, isNew, err = InsertWebhookEventIfNew(ctx, tx, s.provider.Name(), event.EventID, event.EventType, payloadHash, rawPayload, true)
		return err
	})
	if err != nil {
		return fmt.Errorf("record webhook event: %w", err)
	}
	if !isNew {
		// Exactly the PRD A11 guarantee: a redelivered webhook is a silent
		// no-op from here — no payment, no ledger entry, no journal, nothing.
		return nil
	}

	var intent *Intent
	err = s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		var err error
		intent, err = FindIntentByOrderReference(ctx, tx, s.provider.Name(), event.ProviderOrderReference)
		return err
	})
	if err != nil {
		markErr := s.markEventError(ctx, eventRowID, "INTENT_NOT_FOUND")
		if markErr != nil {
			return fmt.Errorf("%w (and failed to record error: %v)", ErrIntentNotFound, markErr)
		}
		return ErrIntentNotFound
	}

	if event.Status == "SUCCESS" && !event.Amount.Equal(intent.Amount) {
		_ = s.markEventError(ctx, eventRowID, "AMOUNT_MISMATCH")
		return fmt.Errorf("%w: expected %s, got %s", ErrAmountMismatch, intent.Amount, event.Amount)
	}

	err = s.db.WithTenantTx(ctx, intent.TenantID, func(tx pgx.Tx) error {
		switch event.Status {
		case "SUCCESS":
			created, err := InsertPaymentIfNew(ctx, tx, intent.TenantID, &PaymentRecord{
				PaymentIntentID: intent.ID, Provider: s.provider.Name(), ProviderPaymentID: event.ProviderPaymentID,
				Method: "UPI", Amount: event.Amount, Status: "SUCCESS",
			})
			if err != nil {
				return fmt.Errorf("insert payment: %w", err)
			}
			if !created {
				// The (provider, provider_payment_id) unique constraint caught a
				// duplicate that slipped past the event-id gate (e.g. two
				// different event IDs for the same underlying payment) — still
				// a no-op, not an error.
				return nil
			}
			if err := UpdateIntentStatus(ctx, tx, intent.ID, "SUCCESS"); err != nil {
				return fmt.Errorf("update intent status: %w", err)
			}
			if intent.CustomerID != nil {
				if err := postReceiptLedgerAndJournal(ctx, tx, intent.TenantID, *intent.CustomerID, intent.ID, event.Amount); err != nil {
					return fmt.Errorf("post receipt ledger/journal: %w", err)
				}
			}
		case "FAILED", "EXPIRED":
			if err := UpdateIntentStatus(ctx, tx, intent.ID, event.Status); err != nil {
				return fmt.Errorf("update intent status: %w", err)
			}
		default:
			return fmt.Errorf("%w: unknown webhook status %q", ErrValidation, event.Status)
		}
		return nil
	})
	if err != nil {
		_ = s.markEventError(ctx, eventRowID, "PROCESSING_ERROR")
		return err
	}

	return s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		return MarkWebhookEventProcessed(ctx, tx, eventRowID, &intent.TenantID, "PROCESSED", nil)
	})
}

func (s *Service) markEventError(ctx context.Context, eventRowID uuid.UUID, code string) error {
	return s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		return MarkWebhookEventProcessed(ctx, tx, eventRowID, nil, "ERROR", &code)
	})
}

// postReceiptLedgerAndJournal credits the customer's ledger (reducing their
// outstanding receivable) and posts the matching balanced journal entry:
// Dr UPI Clearing, Cr Accounts Receivable.
func postReceiptLedgerAndJournal(ctx context.Context, tx pgx.Tx, tenantID, customerID, paymentID uuid.UUID, amount decimal.Decimal) error {
	if _, err := customer.PostLedgerEntry(ctx, tx, tenantID, customer.LedgerEntry{
		CustomerID: customerID, DocumentType: "RECEIPT", DocumentID: paymentID,
		Debit: decimal.Zero, Credit: amount, Description: "UPI receipt",
	}); err != nil {
		return err
	}

	financialYearID, err := accounting.GetActiveFinancialYear(ctx, tx, tenantID)
	if err != nil {
		return err
	}
	upiAccountID, err := accounting.GetOrCreateAccount(ctx, tx, tenantID, "UPI_CLEARING", "UPI Clearing Account", "ASSET")
	if err != nil {
		return err
	}
	receivableAccountID, err := accounting.GetOrCreateAccount(ctx, tx, tenantID, "ACCOUNTS_RECEIVABLE", "Trade Receivables", "ASSET")
	if err != nil {
		return err
	}
	journalNumber := "JRNL-RCPT-" + paymentID.String()[:8]
	_, err = accounting.PostJournal(ctx, tx, tenantID, financialYearID, journalNumber, "RECEIPT", paymentID, "UPI receipt", []accounting.JournalLine{
		{AccountID: upiAccountID, Debit: amount, Credit: decimal.Zero, Description: "UPI receipt received"},
		{AccountID: receivableAccountID, Debit: decimal.Zero, Credit: amount, CustomerID: &customerID, Description: "Receivable settled"},
	})
	return err
}

// manualReceiptAccountCode mirrors pos.tenderAccountCode's mapping for the
// same three methods a manual receipt supports — kept as its own small copy
// rather than importing the pos package, to keep payment/pos free of a
// cross-domain dependency for one switch statement.
func manualReceiptAccountCode(method string) (code, name string) {
	switch method {
	case "CASH":
		return "CASH", "Cash on Hand"
	case "BANK":
		return "BANK", "Bank Account"
	default:
		return "OTHER_SETTLEMENT", "Other Settlement"
	}
}

// postManualReceiptLedgerAndJournal is postReceiptLedgerAndJournal's
// counterpart for a receipt collected in person rather than confirmed by a
// payment provider: same ledger/journal shape, but the debit lands in
// whichever account the method (cash/bank/other) actually settles into
// instead of always UPI Clearing.
func postManualReceiptLedgerAndJournal(ctx context.Context, tx pgx.Tx, tenantID, customerID, paymentID uuid.UUID, method string, amount decimal.Decimal) error {
	description := manualReceiptDescription(method)
	if _, err := customer.PostLedgerEntry(ctx, tx, tenantID, customer.LedgerEntry{
		CustomerID: customerID, DocumentType: "RECEIPT", DocumentID: paymentID,
		Debit: decimal.Zero, Credit: amount, Description: description,
	}); err != nil {
		return err
	}

	financialYearID, err := accounting.GetActiveFinancialYear(ctx, tx, tenantID)
	if err != nil {
		return err
	}
	code, name := manualReceiptAccountCode(method)
	settlementAccountID, err := accounting.GetOrCreateAccount(ctx, tx, tenantID, code, name, "ASSET")
	if err != nil {
		return err
	}
	receivableAccountID, err := accounting.GetOrCreateAccount(ctx, tx, tenantID, "ACCOUNTS_RECEIVABLE", "Trade Receivables", "ASSET")
	if err != nil {
		return err
	}
	journalNumber := "JRNL-RCPT-" + paymentID.String()[:8]
	_, err = accounting.PostJournal(ctx, tx, tenantID, financialYearID, journalNumber, "RECEIPT", paymentID, description, []accounting.JournalLine{
		{AccountID: settlementAccountID, Debit: amount, Credit: decimal.Zero, Description: description},
		{AccountID: receivableAccountID, Debit: decimal.Zero, Credit: amount, CustomerID: &customerID, Description: "Receivable settled"},
	})
	return err
}

func manualReceiptDescription(method string) string {
	switch method {
	case "CASH":
		return "Cash receipt"
	case "BANK":
		return "Bank receipt"
	default:
		return "Receipt"
	}
}

func manualPaymentDescription(method string) string {
	switch method {
	case "CASH":
		return "Cash payment"
	case "BANK":
		return "Bank payment"
	default:
		return "Payment"
	}
}

// postSupplierPaymentLedgerAndJournal is postManualReceiptLedgerAndJournal's
// mirror on the payable side: a debit to the supplier ledger (decreasing
// what the shop owes — see supplier.PostLedgerEntry) and a journal Dr
// Accounts Payable / Cr whichever account the method actually settles from.
func postSupplierPaymentLedgerAndJournal(ctx context.Context, tx pgx.Tx, tenantID, supplierID, paymentID uuid.UUID, method string, amount decimal.Decimal) error {
	description := manualPaymentDescription(method)
	if _, err := supplier.PostLedgerEntry(ctx, tx, tenantID, supplier.LedgerEntry{
		SupplierID: supplierID, DocumentType: "PAYMENT", DocumentID: paymentID,
		Debit: amount, Credit: decimal.Zero, Description: description,
	}); err != nil {
		return err
	}

	financialYearID, err := accounting.GetActiveFinancialYear(ctx, tx, tenantID)
	if err != nil {
		return err
	}
	code, name := manualReceiptAccountCode(method)
	settlementAccountID, err := accounting.GetOrCreateAccount(ctx, tx, tenantID, code, name, "ASSET")
	if err != nil {
		return err
	}
	payableAccountID, err := accounting.GetOrCreateAccount(ctx, tx, tenantID, "ACCOUNTS_PAYABLE", "Trade Payables", "LIABILITY")
	if err != nil {
		return err
	}
	journalNumber := "JRNL-PMT-" + paymentID.String()[:8]
	_, err = accounting.PostJournal(ctx, tx, tenantID, financialYearID, journalNumber, "PAYMENT", paymentID, description, []accounting.JournalLine{
		{AccountID: payableAccountID, Debit: amount, Credit: decimal.Zero, SupplierID: &supplierID, Description: "Payable settled"},
		{AccountID: settlementAccountID, Debit: decimal.Zero, Credit: amount, Description: description},
	})
	return err
}
