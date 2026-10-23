package cloudusage

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
)

// RunPollOnce polls every provider, persists a snapshot per metric, and
// raises or auto-resolves threshold alerts — one self-contained pass,
// exactly like subscription.RunBillingCycleOnce, so it's safe to call on a
// ticker or on demand (the "Refresh now" button) without any shared state
// between calls.
func (s *Service) RunPollOnce(ctx context.Context) (polled int, err error) {
	metrics := s.PollAll(ctx)

	err = s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		thresholds, err := listThresholds(ctx, tx)
		if err != nil {
			return fmt.Errorf("list thresholds: %w", err)
		}
		thresholdByMetric := make(map[string]Threshold, len(thresholds))
		for _, t := range thresholds {
			thresholdByMetric[t.Provider+"/"+t.MetricKey] = t
		}

		for _, m := range metrics {
			if err := insertSnapshot(ctx, tx, m); err != nil {
				return fmt.Errorf("insert snapshot %s/%s: %w", m.Provider, m.MetricKey, err)
			}
			if m.LimitValue == nil || *m.LimitValue <= 0 {
				continue
			}
			pct := m.UsedValue / *m.LimitValue * 100
			t, ok := thresholdByMetric[m.Provider+"/"+m.MetricKey]
			if !ok {
				continue
			}

			switch {
			case pct >= t.CriticalPct:
				if err := raiseAlertOnce(ctx, tx, m, "critical", pct); err != nil {
					return err
				}
			case pct >= t.WarningPct:
				if err := raiseAlertOnce(ctx, tx, m, "warning", pct); err != nil {
					return err
				}
			default:
				if err := resolveAlerts(ctx, tx, m.Provider, m.MetricKey); err != nil {
					return fmt.Errorf("resolve alerts %s/%s: %w", m.Provider, m.MetricKey, err)
				}
			}
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	return len(metrics), nil
}

func raiseAlertOnce(ctx context.Context, tx pgx.Tx, m Metric, severity string, pct float64) error {
	already, err := hasOpenAlert(ctx, tx, m.Provider, m.MetricKey, severity)
	if err != nil {
		return fmt.Errorf("check open alert %s/%s: %w", m.Provider, m.MetricKey, err)
	}
	if already {
		return nil
	}
	message := fmt.Sprintf("%s is at %.1f%% of its free-tier limit", m.Label, pct)
	return insertAlert(ctx, tx, m.Provider, m.MetricKey, severity, message, pct)
}

// StartUsagePollScheduler mirrors subscription.Service.StartBillingScheduler:
// runs once immediately, then once every tickInterval until ctx is
// cancelled. A single failed run (a provider API blip, a bad token) is
// logged and never stops future runs.
//
// Only reliable on a host where the process runs continuously (self-hosted
// / VPS). On Cloud Run's scale-to-zero this ticker was found to only ever
// fire at container boot, never on its own schedule while idle — see
// CRON_SECRET / cron_handlers.go for the fix used there (Google Cloud
// Scheduler calling RunPollOnce directly via an authenticated endpoint).
func (s *Service) StartUsagePollScheduler(ctx context.Context, tickInterval time.Duration) {
	run := func() {
		polled, err := s.RunPollOnce(ctx)
		if err != nil {
			slog.Error("cloud usage poll run failed", "error", err)
			return
		}
		slog.Info("cloud usage poll run completed", "metrics_polled", polled)
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

// ListLatestUsage and ListActiveAlerts are the read paths for the platform
// admin dashboard — both just read the latest persisted snapshot/alert
// rows, never calling out to a provider live (that only happens in
// RunPollOnce), so a page load is always fast and never burns provider API
// quota.
func (s *Service) ListLatestUsage(ctx context.Context) ([]LatestUsage, error) {
	var out []LatestUsage
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = listLatestUsage(ctx, tx)
		return err
	})
	return out, err
}

func (s *Service) ListActiveAlerts(ctx context.Context) ([]Alert, error) {
	var out []Alert
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = listActiveAlerts(ctx, tx)
		return err
	})
	return out, err
}

func (s *Service) UpdateThreshold(ctx context.Context, id string, warningPct, criticalPct float64) error {
	return s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		return updateThreshold(ctx, tx, id, warningPct, criticalPct)
	})
}
