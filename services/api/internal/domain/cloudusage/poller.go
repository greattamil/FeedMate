package cloudusage

import (
	"context"
	"log/slog"
)

// PollAll queries every configured provider and returns whatever metrics
// it could get. One provider failing (bad credentials, a transient network
// blip, a provider API change) never blocks the others — each poller
// swallows its own errors into a slog.Warn and returns what it has.
func (s *Service) PollAll(ctx context.Context) []Metric {
	var all []Metric

	if gcpMetrics, err := s.pollGCP(ctx); err != nil {
		slog.Warn("cloudusage: gcp poll failed", "error", err)
	} else {
		all = append(all, gcpMetrics...)
	}

	if cfMetrics, err := s.pollCloudflare(ctx); err != nil {
		slog.Warn("cloudusage: cloudflare poll failed", "error", err)
	} else {
		all = append(all, cfMetrics...)
	}

	if aivenMetrics, err := s.pollAiven(ctx); err != nil {
		slog.Warn("cloudusage: aiven poll failed", "error", err)
	} else {
		all = append(all, aivenMetrics...)
	}

	return all
}
