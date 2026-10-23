package cloudusage

import (
	"context"

	"github.com/jackc/pgx/v5"
)

func insertSnapshot(ctx context.Context, tx pgx.Tx, m Metric) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO cloud_usage_snapshots (provider, metric_key, label, used_value, limit_value, limit_is_live, unit, raw_json)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
	`, m.Provider, m.MetricKey, m.Label, m.UsedValue, m.LimitValue, m.LimitIsLive, m.Unit, m.Raw)
	return err
}

func listThresholds(ctx context.Context, tx pgx.Tx) ([]Threshold, error) {
	rows, err := tx.Query(ctx, `SELECT id, provider, metric_key, warning_pct, critical_pct FROM cloud_usage_thresholds`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Threshold
	for rows.Next() {
		var t Threshold
		if err := rows.Scan(&t.ID, &t.Provider, &t.MetricKey, &t.WarningPct, &t.CriticalPct); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func updateThreshold(ctx context.Context, tx pgx.Tx, id string, warningPct, criticalPct float64) error {
	_, err := tx.Exec(ctx, `
		UPDATE cloud_usage_thresholds SET warning_pct = $2, critical_pct = $3, updated_at = now() WHERE id = $1
	`, id, warningPct, criticalPct)
	return err
}

func insertAlert(ctx context.Context, tx pgx.Tx, provider, metricKey, severity, message string, pctUsed float64) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO cloud_usage_alerts (provider, metric_key, severity, message, pct_used)
		VALUES ($1, $2, $3, $4, $5)
	`, provider, metricKey, severity, message, pctUsed)
	return err
}

// resolveAlerts closes any still-open alert for this provider/metric — used
// when a fresh poll shows usage has dropped back under the warning
// threshold, so the admin UI doesn't keep showing a stale breach.
func resolveAlerts(ctx context.Context, tx pgx.Tx, provider, metricKey string) error {
	_, err := tx.Exec(ctx, `
		UPDATE cloud_usage_alerts SET resolved_at = now()
		WHERE provider = $1 AND metric_key = $2 AND resolved_at IS NULL
	`, provider, metricKey)
	return err
}

// hasOpenAlert reports whether an unresolved alert of at least this
// severity already exists for this metric, so re-polling every hour
// doesn't spam a new alert row each time while a breach persists.
func hasOpenAlert(ctx context.Context, tx pgx.Tx, provider, metricKey, severity string) (bool, error) {
	var exists bool
	err := tx.QueryRow(ctx, `
		SELECT EXISTS(
			SELECT 1 FROM cloud_usage_alerts
			WHERE provider = $1 AND metric_key = $2 AND severity = $3 AND resolved_at IS NULL
		)
	`, provider, metricKey, severity).Scan(&exists)
	return exists, err
}

func listLatestUsage(ctx context.Context, tx pgx.Tx) ([]LatestUsage, error) {
	rows, err := tx.Query(ctx, `
		SELECT DISTINCT ON (provider, metric_key)
			provider, metric_key, label, used_value, limit_value, limit_is_live, unit, captured_at
		FROM cloud_usage_snapshots
		ORDER BY provider, metric_key, captured_at DESC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []LatestUsage
	for rows.Next() {
		var u LatestUsage
		if err := rows.Scan(&u.Provider, &u.MetricKey, &u.Label, &u.UsedValue, &u.LimitValue, &u.LimitIsLive, &u.Unit, &u.CapturedAt); err != nil {
			return nil, err
		}
		if u.LimitValue != nil && *u.LimitValue > 0 {
			pct := u.UsedValue / *u.LimitValue * 100
			u.PctUsed = &pct
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

func listActiveAlerts(ctx context.Context, tx pgx.Tx) ([]Alert, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, provider, metric_key, severity, message, pct_used, created_at, resolved_at
		FROM cloud_usage_alerts
		WHERE resolved_at IS NULL
		ORDER BY created_at DESC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Alert
	for rows.Next() {
		var a Alert
		if err := rows.Scan(&a.ID, &a.Provider, &a.MetricKey, &a.Severity, &a.Message, &a.PctUsed, &a.CreatedAt, &a.ResolvedAt); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}
