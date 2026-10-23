package subscription

import (
	"context"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
)

// BillingCycleResult reports what one RunBillingCycleOnce pass did, for
// logging.
type BillingCycleResult struct {
	MarkedPastDue int
	Suspended     int
}

// RunBillingCycleOnce performs one pass, in two independent steps:
//
//  1. Any ACTIVE subscription whose current_period_end has already passed
//     goes PAST_DUE and gets past_due_since stamped. Period advancement is
//     deliberately NOT this job's job — it happens only inside
//     Service.RecordManualPayment, the moment a qualifying payment is
//     recorded — so arriving here with an unadvanced, past-due period
//     means, by construction, no payment has been recorded for it.
//  2. Any PAST_DUE subscription whose grace period (a tenant-specific
//     override if set, else the plan's own default) has elapsed gets
//     SUSPENDED, and the tenant itself is suspended in the same
//     statement.
//
// Idempotent and safe to run more than once a day, or to miss a day
// entirely: every decision is "has enough time now passed", never "did
// exactly one day pass" — a missed run just catches up fully on the next
// one.
func RunBillingCycleOnce(ctx context.Context, tx pgx.Tx, now time.Time) (BillingCycleResult, error) {
	var result BillingCycleResult

	tag, err := tx.Exec(ctx, `
		UPDATE tenant_subscriptions
		SET status = 'PAST_DUE', past_due_since = $1, updated_at = $1
		WHERE status = 'ACTIVE' AND current_period_end < $1::date
	`, now)
	if err != nil {
		return result, err
	}
	result.MarkedPastDue = int(tag.RowsAffected())

	tag, err = tx.Exec(ctx, `
		WITH to_suspend AS (
			UPDATE tenant_subscriptions ts
			SET status = 'SUSPENDED', updated_at = $1
			FROM subscription_plans sp
			WHERE ts.plan_id = sp.id
			  AND ts.status = 'PAST_DUE'
			  AND ts.past_due_since < $1::timestamptz - (COALESCE(ts.grace_period_days, sp.grace_period_days) || ' days')::interval
			RETURNING ts.tenant_id
		)
		UPDATE tenants SET status = 'SUSPENDED', updated_at = $1
		WHERE id IN (SELECT tenant_id FROM to_suspend) AND status != 'SUSPENDED'
	`, now)
	if err != nil {
		return result, err
	}
	result.Suspended = int(tag.RowsAffected())

	return result, nil
}

// RunBillingCycleNow wraps RunBillingCycleOnce in an admin transaction —
// the single reusable "do it once" entrypoint called both by
// StartBillingScheduler's ticker (self-hosted/VPS deployments, where the
// process runs continuously so an in-process ticker is reliable) and by
// the /internal/cron/billing-cycle handler that Google Cloud Scheduler
// calls on Cloud Run (where it is NOT reliable — see that handler's doc
// comment for why).
func (s *Service) RunBillingCycleNow(ctx context.Context) (BillingCycleResult, error) {
	var result BillingCycleResult
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		var err error
		result, err = RunBillingCycleOnce(ctx, tx, time.Now().UTC())
		return err
	})
	return result, err
}

// StartBillingScheduler runs RunBillingCycleNow once immediately, then
// once every tickInterval (24h in production; shorter in tests) until ctx
// is cancelled. A single run's error is logged and never stops future
// runs — a transient DB blip (see this session's intermittent Aiven DNS
// issue) must not permanently wedge billing.
//
// Only reliable on a host where the process runs continuously (self-hosted
// / VPS via docker-compose.prod.yml). On Cloud Run's scale-to-zero, CPU is
// frozen between requests and the container can be torn down entirely
// while idle, so this ticker was found to only ever fire at container
// boot — see CRON_SECRET / cron_handlers.go for the fix used there.
func (s *Service) StartBillingScheduler(ctx context.Context, tickInterval time.Duration) {
	run := func() {
		result, err := s.RunBillingCycleNow(ctx)
		if err != nil {
			slog.Error("billing cycle run failed", "error", err)
			return
		}
		slog.Info("billing cycle run completed", "marked_past_due", result.MarkedPastDue, "suspended", result.Suspended)
	}

	run()
	ticker := time.NewTicker(tickInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			run()
		}
	}
}
