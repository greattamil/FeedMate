package customer

import (
	"context"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

// OverdueSummary is one tenant's result from a RunOverdueSweepNow pass —
// never one row per customer (that would mean one push per overdue
// customer per day, which is exactly the kind of notification fatigue
// this feature is meant to avoid); the caller sends at most one summary
// push per tenant.
type OverdueSummary struct {
	TenantID         uuid.UUID
	OverdueCount     int
	TotalOutstanding decimal.Decimal
}

// RunOverdueSweepNow finds, across every ACTIVE tenant, customers with a
// positive outstanding ledger balance who have seen no ledger activity
// (a sale or a payment) in at least that tenant's own
// reminder_days_before + grace_period_days (tenant_settings — see
// migration 0001). This is an activity-based proxy for "payment
// overdue", not true per-invoice due-date aging: the schema has no
// invoice due_date today, so "overdue" here means "still owes money and
// nothing has happened on their account in a while", which is the
// signal a small shop owner actually wants a daily nudge about.
//
// Runs as a single cross-tenant query under WithAdminTx, the same shape
// as subscription.RunBillingCycleOnce — intentionally one query rather
// than looping per tenant, since every tenant's threshold can be
// expressed in the same WHERE clause via a join to its own
// tenant_settings row. Returns only tenants that actually have at least
// one overdue customer (a zero-row result means nothing to report), for
// the cron handler to turn into pushes via notify.Service.Dispatch —
// this function has no knowledge of pushnotify/notify.
func (s *Service) RunOverdueSweepNow(ctx context.Context) ([]OverdueSummary, error) {
	var out []OverdueSummary
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT ts.tenant_id, count(*), COALESCE(SUM(b.balance), 0)
			FROM tenant_settings ts
			JOIN tenants t ON t.id = ts.tenant_id AND t.status = 'ACTIVE'
			JOIN LATERAL (
				SELECT cle.customer_id,
				       SUM(cle.debit) - SUM(cle.credit) AS balance,
				       MAX(cle.entry_date) AS last_activity
				FROM customer_ledger_entries cle
				WHERE cle.tenant_id = ts.tenant_id
				GROUP BY cle.customer_id
			) b ON b.balance > 0
			   AND b.last_activity < now() - ((ts.reminder_days_before + ts.grace_period_days) || ' days')::interval
			GROUP BY ts.tenant_id
		`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var s OverdueSummary
			if err := rows.Scan(&s.TenantID, &s.OverdueCount, &s.TotalOutstanding); err != nil {
				return err
			}
			out = append(out, s)
		}
		return rows.Err()
	})
	return out, err
}
