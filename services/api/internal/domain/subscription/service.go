package subscription

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
)

var ErrValidation = errors.New("validation error")

type Service struct {
	db *dbctx.DB
}

func NewService(db *dbctx.DB) *Service {
	return &Service{db: db}
}

func (s *Service) ListPlans(ctx context.Context) ([]Plan, error) {
	var out []Plan
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = ListPlans(ctx, tx)
		return err
	})
	return out, err
}

type CreatePlanInput struct {
	Code            string
	Name            string
	Price           decimal.Decimal
	GracePeriodDays int
}

func (s *Service) CreatePlan(ctx context.Context, in CreatePlanInput) (uuid.UUID, error) {
	if in.Code == "" || in.Name == "" {
		return uuid.Nil, fmt.Errorf("%w: code and name are required", ErrValidation)
	}
	if in.Price.IsNegative() {
		return uuid.Nil, fmt.Errorf("%w: price cannot be negative", ErrValidation)
	}
	if in.GracePeriodDays < 0 {
		return uuid.Nil, fmt.Errorf("%w: grace_period_days cannot be negative", ErrValidation)
	}
	var id uuid.UUID
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		var err error
		id, err = InsertPlan(ctx, tx, InsertPlanInput{Code: in.Code, Name: in.Name, Price: in.Price, GracePeriodDays: in.GracePeriodDays})
		return err
	})
	if err != nil {
		return uuid.Nil, err
	}
	return id, nil
}

func (s *Service) UpdatePlan(ctx context.Context, id uuid.UUID, in UpdatePlanInput) error {
	if in.Name == "" {
		return fmt.Errorf("%w: name is required", ErrValidation)
	}
	if in.Price.IsNegative() {
		return fmt.Errorf("%w: price cannot be negative", ErrValidation)
	}
	if in.GracePeriodDays < 0 {
		return fmt.Errorf("%w: grace_period_days cannot be negative", ErrValidation)
	}
	return s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		return UpdatePlan(ctx, tx, id, UpdatePlanInput{Name: in.Name, Price: in.Price, GracePeriodDays: in.GracePeriodDays, Active: in.Active})
	})
}

func (s *Service) GetTenantSubscription(ctx context.Context, tenantID uuid.UUID) (*TenantSubscription, error) {
	var out *TenantSubscription
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = GetTenantSubscription(ctx, tx, tenantID)
		return err
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// addOneMonth is the single place "one billing period" is defined — a
// calendar month, matching billing_period's current MONTHLY-only CHECK.
func addOneMonth(t time.Time) time.Time {
	return t.AddDate(0, 1, 0)
}

// SetTenantPlan assigns or changes a tenant's plan, starting at
// periodStart (default: today) and running for one full calendar month —
// no proration, the new price applies to the period in full starting from
// whenever the platform admin makes the change. Keeps tenants.plan_code/
// plan_expires_at in sync for the existing tenant list/summary UI.
func (s *Service) SetTenantPlan(ctx context.Context, tenantID, planID uuid.UUID, periodStart *time.Time) error {
	start := time.Now().UTC().Truncate(24 * time.Hour)
	if periodStart != nil {
		start = periodStart.UTC().Truncate(24 * time.Hour)
	}
	end := addOneMonth(start)

	return s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		plan, err := GetPlanByID(ctx, tx, planID)
		if err != nil {
			return err
		}
		if err := UpsertTenantSubscription(ctx, tx, tenantID, planID, start, end); err != nil {
			return err
		}
		return SyncTenantPlanCache(ctx, tx, tenantID, plan.Code, end)
	})
}

type RecordPaymentInput struct {
	Amount          decimal.Decimal
	Method          string
	Reference       string
	Notes           string
	IdempotencyKey  string
	PlatformAdminID uuid.UUID
}

type RecordPaymentResult struct {
	PaymentID uuid.UUID
	Duplicate bool
}

var validPaymentMethods = map[string]bool{"CASH": true, "BANK": true, "UPI": true, "OTHER": true}

// RecordManualPayment follows payment.Service.RecordManualReceipt's
// idempotent-insert shape exactly (see that package's doc comment on why
// an authenticated actor's own recorded action is itself the
// confirmation — the same trust model applies here, just at the platform
// level rather than the tenant level). A payment that covers the
// subscription's current/overdue period advances the period by one month,
// clears PAST_DUE, and — per the confirmed product decision — auto-
// reactivates the tenant if it was SUSPENDED.
func (s *Service) RecordManualPayment(ctx context.Context, tenantID uuid.UUID, in RecordPaymentInput) (*RecordPaymentResult, error) {
	if in.Amount.LessThanOrEqual(decimal.Zero) {
		return nil, fmt.Errorf("%w: amount must be positive", ErrValidation)
	}
	if !validPaymentMethods[in.Method] {
		return nil, fmt.Errorf("%w: method must be one of CASH, BANK, UPI, OTHER", ErrValidation)
	}
	if in.IdempotencyKey == "" {
		return nil, fmt.Errorf("%w: idempotency_key is required", ErrValidation)
	}

	var result RecordPaymentResult
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		sub, err := GetTenantSubscription(ctx, tx, tenantID)
		if err != nil {
			return fmt.Errorf("load subscription: %w", err)
		}

		id, created, err := InsertPaymentIfNew(ctx, tx, tenantID, in.PlatformAdminID, in.Amount, sub.CurrentPeriodStart, sub.CurrentPeriodEnd, in.Method, in.Reference, in.Notes, in.IdempotencyKey)
		if err != nil {
			return fmt.Errorf("insert payment: %w", err)
		}
		if !created {
			existing, err := FindPaymentByIdempotencyKey(ctx, tx, tenantID, in.IdempotencyKey)
			if err != nil {
				return fmt.Errorf("resolve duplicate payment: %w", err)
			}
			result = RecordPaymentResult{PaymentID: existing.ID, Duplicate: true}
			return nil
		}

		newStart := sub.CurrentPeriodEnd
		newEnd := addOneMonth(newStart)
		if err := AdvanceSubscriptionPeriod(ctx, tx, tenantID, newStart, newEnd); err != nil {
			return fmt.Errorf("advance subscription period: %w", err)
		}
		if err := SyncTenantPlanCache(ctx, tx, tenantID, sub.PlanCode, newEnd); err != nil {
			return fmt.Errorf("sync tenant plan cache: %w", err)
		}
		if err := SetTenantActiveIfSuspended(ctx, tx, tenantID); err != nil {
			return fmt.Errorf("reactivate tenant: %w", err)
		}
		result = RecordPaymentResult{PaymentID: id, Duplicate: false}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

func (s *Service) ListBillingHistory(ctx context.Context, tenantID uuid.UUID, limit, offset int) ([]PaymentEntry, int, error) {
	var out []PaymentEntry
	var total int
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		var err error
		out, total, err = ListBillingHistory(ctx, tx, tenantID, limit, offset)
		return err
	})
	return out, total, err
}
