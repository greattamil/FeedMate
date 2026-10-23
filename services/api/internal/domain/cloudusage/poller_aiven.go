package cloudusage

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"

	"github.com/jackc/pgx/v5"
)

// pollAiven combines two live sources: the actual Postgres database size
// (via pg_database_size, run directly against the real DB — the most
// precise possible measure of disk usage) for the "used" side, and the
// Aiven API's reported disk_space_mb for the "limit" side, since the plan's
// disk cap can change if the plan is ever resized and must not be assumed.
func (s *Service) pollAiven(ctx context.Context) ([]Metric, error) {
	var usedBytes float64
	err := s.db.WithAdminTx(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT pg_database_size(current_database())`).Scan(&usedBytes)
	})
	if err != nil {
		return nil, fmt.Errorf("query pg_database_size: %w", err)
	}

	metric := Metric{
		Provider: "aiven", MetricKey: "postgres_disk_bytes", Label: "Postgres disk usage",
		UsedValue: usedBytes, Unit: "bytes",
	}

	if s.aivenAPIToken != "" && s.aivenProject != "" && s.aivenService != "" {
		limitBytes, raw, err := s.fetchAivenDiskLimit(ctx)
		if err != nil {
			slog.Warn("cloudusage: aiven disk limit fetch failed", "error", err)
		} else {
			metric.LimitValue = floatPtr(limitBytes)
			metric.LimitIsLive = true
			metric.Raw = raw
		}
	}

	return []Metric{metric}, nil
}

func (s *Service) fetchAivenDiskLimit(ctx context.Context) (float64, []byte, error) {
	url := fmt.Sprintf("https://api.aiven.io/v1/project/%s/service/%s", s.aivenProject, s.aivenService)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "aivenv1 "+s.aivenAPIToken)

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return 0, body, fmt.Errorf("aiven API returned %d: %s", resp.StatusCode, body)
	}

	var parsed struct {
		Service struct {
			DiskSpaceMB float64 `json:"disk_space_mb"`
		} `json:"service"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return 0, body, err
	}
	if parsed.Service.DiskSpaceMB == 0 {
		return 0, body, fmt.Errorf("disk_space_mb not present or zero in aiven response")
	}
	return parsed.Service.DiskSpaceMB * 1024 * 1024, body, nil
}
