package cloudusage

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/andipatti/feedmate/services/api/internal/gcpauth"
)

// gcpFreeTierRequests and gcpFreeTierInstanceSeconds are Google's published
// Cloud Run free-tier allowances. Google does not expose these ceilings via
// any API (confirmed during planning) — they are fixed facts from
// https://cloud.google.com/run/pricing, recorded with LimitIsLive=false so
// the UI never implies they were fetched live. Only the usage side of these
// metrics is live.
const (
	gcpFreeTierRequests       = 2_000_000
	gcpFreeTierInstanceSeconds = 180_000
)

// pollGCP fetches an access token from the Cloud Run instance's own
// metadata server (Application Default Credentials — no service-account
// key is stored anywhere) and queries Cloud Monitoring for this month's
// Cloud Run request count and billable instance time.
func (s *Service) pollGCP(ctx context.Context) ([]Metric, error) {
	if s.gcpProjectID == "" {
		return nil, nil
	}
	token, err := gcpauth.FetchToken(ctx, s.httpClient)
	if err != nil {
		return nil, fmt.Errorf("fetch GCP metadata token: %w", err)
	}

	now := time.Now().UTC()
	monthStart := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)

	requests, rawRequests, err := s.queryMonitoringSum(ctx, token, "run.googleapis.com/request_count", monthStart, now)
	if err != nil {
		slog.Warn("cloudusage: gcp request_count query failed", "error", err)
	}
	instanceSeconds, rawInstance, err := s.queryMonitoringSum(ctx, token, "run.googleapis.com/container/billable_instance_time", monthStart, now)
	if err != nil {
		slog.Warn("cloudusage: gcp billable_instance_time query failed", "error", err)
	}

	return []Metric{
		{
			Provider: "gcp", MetricKey: "cloud_run_requests", Label: "Cloud Run requests (this month)",
			UsedValue: requests, LimitValue: floatPtr(gcpFreeTierRequests), LimitIsLive: false,
			Unit: "count", Raw: rawRequests,
		},
		{
			Provider: "gcp", MetricKey: "cloud_run_billable_instance_seconds", Label: "Cloud Run billable instance time (this month)",
			UsedValue: instanceSeconds, LimitValue: floatPtr(gcpFreeTierInstanceSeconds), LimitIsLive: false,
			Unit: "seconds", Raw: rawInstance,
		},
	}, nil
}

// queryMonitoringSum sums a Cloud Run metric across every revision/instance
// for the given window via the Cloud Monitoring API, using a single
// alignment period spanning the whole window so the API itself does the
// summation.
func (s *Service) queryMonitoringSum(ctx context.Context, token, metricType string, start, end time.Time) (float64, []byte, error) {
	alignmentSeconds := int(end.Sub(start).Seconds())
	if alignmentSeconds < 1 {
		alignmentSeconds = 1
	}
	filter := fmt.Sprintf(`metric.type="%s" AND resource.type="cloud_run_revision"`, metricType)

	q := url.Values{}
	q.Set("filter", filter)
	q.Set("interval.startTime", start.Format(time.RFC3339))
	q.Set("interval.endTime", end.Format(time.RFC3339))
	q.Set("aggregation.alignmentPeriod", strconv.Itoa(alignmentSeconds)+"s")
	q.Set("aggregation.perSeriesAligner", "ALIGN_SUM")
	q.Set("aggregation.crossSeriesReducer", "REDUCE_SUM")

	reqURL := fmt.Sprintf("https://monitoring.googleapis.com/v3/projects/%s/timeSeries?%s", s.gcpProjectID, q.Encode())
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, reqURL, nil)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return 0, body, fmt.Errorf("monitoring API returned %d: %s", resp.StatusCode, body)
	}

	var parsed struct {
		TimeSeries []struct {
			Points []struct {
				Value struct {
					Int64Value  string  `json:"int64Value"`
					DoubleValue float64 `json:"doubleValue"`
				} `json:"value"`
			} `json:"points"`
		} `json:"timeSeries"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return 0, body, err
	}

	var total float64
	for _, ts := range parsed.TimeSeries {
		for _, p := range ts.Points {
			if p.Value.Int64Value != "" {
				n, _ := strconv.ParseFloat(p.Value.Int64Value, 64)
				total += n
			} else {
				total += p.Value.DoubleValue
			}
		}
	}
	return total, body, nil
}
