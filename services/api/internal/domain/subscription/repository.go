// Package subscription implements platform-level billing: a catalogue of
// plans, each tenant's current subscription state, and manually-recorded
// payments. This is platform revenue data, not tenant data — same
// GRANT-only-to-app_admin boundary as platformadmin (no RLS needed, there
// is no tenant to isolate from — every row here already belongs
// conceptually to the platform, referencing a tenant only to say which one
// is being billed). Every DB call here runs on dbctx.DB.WithAdminTx.
package subscription

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

var ErrNotFound = errors.New("not found")

type Plan struct {
	ID              uuid.UUID
	Code            string
	Name            string
	Price           decimal.Decimal
	CurrencyCode    string
	BillingPeriod   string
	GracePeriodDays int
	Active          bool
}

func ListPlans(ctx context.Context, tx pgx.Tx) ([]Plan, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, code, name, price, currency_code, billing_period, grace_period_days, active
		FROM subscription_plans ORDER BY price ASC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Plan
	for rows.Next() {
		var p Plan
		if err := rows.Scan(&p.ID, &p.Code, &p.Name, &p.Price, &p.CurrencyCode, &p.BillingPeriod, &p.GracePeriodDays, &p.Active); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func GetPlanByID(ctx context.Context, tx pgx.Tx, id uuid.UUID) (*Plan, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, code, name, price, currency_code, billing_period, grace_period_days, active
		FROM subscription_plans WHERE id = $1
	`, id)
	var p Plan
	if err := row.Scan(&p.ID, &p.Code, &p.Name, &p.Price, &p.CurrencyCode, &p.BillingPeriod, &p.GracePeriodDays, &p.Active); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &p, nil
}

type InsertPlanInput struct {
	Code            string
	Name            string
	Price           decimal.Decimal
	GracePeriodDays int
}

func InsertPlan(ctx context.Context, tx pgx.Tx, in InsertPlanInput) (uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO subscription_plans (code, name, price, grace_period_days)
		VALUES ($1,$2,$3,$4)
		RETURNING id
	`, in.Code, in.Name, in.Price, in.GracePeriodDays).Scan(&id)
	return id, err
}

type UpdatePlanInput struct {
	Name            string
	Price           decimal.Decimal
	GracePeriodDays int
	Active          bool
}

func UpdatePlan(ctx context.Context, tx pgx.Tx, id uuid.UUID, in UpdatePlanInput) error {
	tag, err := tx.Exec(ctx, `
		UPDATE subscription_plans SET name = $2, price = $3, grace_period_days = $4, active = $5, updated_at = now()
		WHERE id = $1
	`, id, in.Name, in.Price, in.GracePeriodDays, in.Active)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// TenantSubscription is one tenant's current billing state plus its plan's
// own name/price/grace period, for the billing tab's summary card.
type TenantSubscription struct {
	ID                 uuid.UUID
	TenantID           uuid.UUID
	PlanID             uuid.UUID
	PlanCode           string
	PlanName           string
	PlanPrice          decimal.Decimal
	Status             string
	CurrentPeriodStart time.Time
	CurrentPeriodEnd   time.Time
	GracePeriodDays    *int
	EffectiveGraceDays int
	PastDueSince       *time.Time
}

func GetTenantSubscription(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID) (*TenantSubscription, error) {
	row := tx.QueryRow(ctx, `
		SELECT ts.id, ts.tenant_id, ts.plan_id, sp.code, sp.name, sp.price, ts.status,
		       ts.current_period_start, ts.current_period_end, ts.grace_period_days,
		       COALESCE(ts.grace_period_days, sp.grace_period_days), ts.past_due_since
		FROM tenant_subscriptions ts
		JOIN subscription_plans sp ON sp.id = ts.plan_id
		WHERE ts.tenant_id = $1
	`, tenantID)
	var s TenantSubscription
	if err := row.Scan(&s.ID, &s.TenantID, &s.PlanID, &s.PlanCode, &s.PlanName, &s.PlanPrice, &s.Status,
		&s.CurrentPeriodStart, &s.CurrentPeriodEnd, &s.GracePeriodDays, &s.EffectiveGraceDays, &s.PastDueSince); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &s, nil
}

// UpsertTenantSubscription assigns or changes a tenant's plan — insert on
// first assignment, update (replacing plan + period, resetting to ACTIVE
// with no past-due state) on a plan change. No proration: the new price
// applies to the period given, in full.
func UpsertTenantSubscription(ctx context.Context, tx pgx.Tx, tenantID, planID uuid.UUID, periodStart, periodEnd time.Time) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO tenant_subscriptions (tenant_id, plan_id, status, current_period_start, current_period_end)
		VALUES ($1, $2, 'ACTIVE', $3, $4)
		ON CONFLICT (tenant_id) DO UPDATE SET
			plan_id = $2, status = 'ACTIVE', current_period_start = $3, current_period_end = $4,
			past_due_since = NULL, updated_at = now()
	`, tenantID, planID, periodStart, periodEnd)
	return err
}

// AdvanceSubscriptionPeriod is called when a qualifying payment is
// recorded: moves the subscription into the paid-for period and clears any
// past-due state.
func AdvanceSubscriptionPeriod(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, periodStart, periodEnd time.Time) error {
	tag, err := tx.Exec(ctx, `
		UPDATE tenant_subscriptions SET
			status = 'ACTIVE', current_period_start = $2, current_period_end = $3, past_due_since = NULL, updated_at = now()
		WHERE tenant_id = $1
	`, tenantID, periodStart, periodEnd)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

type PaymentEntry struct {
	ID          uuid.UUID
	Amount      decimal.Decimal
	PeriodStart time.Time
	PeriodEnd   time.Time
	Method      string
	Reference   *string
	Notes       *string
	PaidAt      time.Time
}

// InsertPaymentIfNew is idempotent on (tenant_id, idempotency_key), the
// same double-submit protection payment.InsertManualPaymentIfNew uses.
func InsertPaymentIfNew(ctx context.Context, tx pgx.Tx, tenantID, platformAdminID uuid.UUID, amount decimal.Decimal, periodStart, periodEnd time.Time, method, reference, notes, idempotencyKey string) (id uuid.UUID, created bool, err error) {
	row := tx.QueryRow(ctx, `
		INSERT INTO subscription_payments (tenant_id, amount, period_start, period_end, method, reference, notes, idempotency_key, recorded_by_platform_admin_id)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
		ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
		RETURNING id
	`, tenantID, amount, periodStart, periodEnd, method, nullIfEmpty(reference), nullIfEmpty(notes), idempotencyKey, platformAdminID)
	if err := row.Scan(&id); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return uuid.Nil, false, nil
		}
		return uuid.Nil, false, err
	}
	return id, true, nil
}

func FindPaymentByIdempotencyKey(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, idempotencyKey string) (*PaymentEntry, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, amount, period_start, period_end, method, reference, notes, paid_at
		FROM subscription_payments WHERE tenant_id = $1 AND idempotency_key = $2
	`, tenantID, idempotencyKey)
	var p PaymentEntry
	if err := row.Scan(&p.ID, &p.Amount, &p.PeriodStart, &p.PeriodEnd, &p.Method, &p.Reference, &p.Notes, &p.PaidAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &p, nil
}

func ListBillingHistory(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, limit, offset int) ([]PaymentEntry, int, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	var total int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM subscription_payments WHERE tenant_id = $1`, tenantID).Scan(&total); err != nil {
		return nil, 0, err
	}
	rows, err := tx.Query(ctx, `
		SELECT id, amount, period_start, period_end, method, reference, notes, paid_at
		FROM subscription_payments WHERE tenant_id = $1
		ORDER BY paid_at DESC
		LIMIT $2 OFFSET $3
	`, tenantID, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []PaymentEntry
	for rows.Next() {
		var p PaymentEntry
		if err := rows.Scan(&p.ID, &p.Amount, &p.PeriodStart, &p.PeriodEnd, &p.Method, &p.Reference, &p.Notes, &p.PaidAt); err != nil {
			return nil, 0, err
		}
		out = append(out, p)
	}
	return out, total, rows.Err()
}

// SetTenantActiveIfSuspended reactivates a tenant whose status was
// SUSPENDED (by the billing job, see billing_job.go) — a qualifying
// payment catching the tenant back up auto-reactivates it; a tenant
// suspended for any other platform-admin reason is left untouched by this
// (it only ever flips SUSPENDED -> ACTIVE, never touches any other
// status).
func SetTenantActiveIfSuspended(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID) error {
	_, err := tx.Exec(ctx, `UPDATE tenants SET status = 'ACTIVE', updated_at = now() WHERE id = $1 AND status = 'SUSPENDED'`, tenantID)
	return err
}

// SyncTenantPlanCache keeps tenants.plan_code/plan_expires_at (the
// pre-existing, now-denormalized display columns the tenant list/summary
// screens already read) in sync with the real subscription state —
// nothing else writes these two columns once this package exists.
func SyncTenantPlanCache(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, planCode string, periodEnd time.Time) error {
	_, err := tx.Exec(ctx, `UPDATE tenants SET plan_code = $2, plan_expires_at = $3, updated_at = now() WHERE id = $1`, tenantID, planCode, periodEnd)
	return err
}

func nullIfEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
