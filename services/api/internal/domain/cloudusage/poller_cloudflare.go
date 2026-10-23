package cloudusage

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"
)

// Cloudflare free-tier ceilings as published at
// https://developers.cloudflare.com/workers/platform/limits/ and
// https://developers.cloudflare.com/r2/platform/limits/. Cloudflare's APIs
// report live usage but, like GCP, never the plan ceiling itself — these
// are fixed facts from Cloudflare's docs, recorded with LimitIsLive=false.
const (
	cfFreeWorkersRequestsPerDay = 100_000
	cfFreeR2StorageBytes        = 10 * 1024 * 1024 * 1024 // 10 GiB
	cfFreeR2ClassAOpsPerMonth   = 1_000_000
)

// Query/field names below were verified against the live GraphQL schema
// for this account (via __type introspection) rather than assumed from
// docs — Cloudflare's dataset names differ from what the docs' examples
// suggest (e.g. account-wide Workers invocation totals live under
// workersInvocationsByOwnerAndScriptGroups, not a "...AdaptiveGroups" name).
const workersQuery = `query($accountTag: String!, $since: String!, $until: String!) {
  viewer {
    accounts(filter: {accountTag: $accountTag}) {
      workersInvocationsByOwnerAndScriptGroups(limit: 1000, filter: {datetime_geq: $since, datetime_leq: $until}) {
        sum { requests }
      }
    }
  }
}`

const r2StorageQuery = `query($accountTag: String!, $since: String!, $until: String!) {
  viewer {
    accounts(filter: {accountTag: $accountTag}) {
      r2StorageAdaptiveGroups(limit: 1, filter: {date_geq: $since, date_leq: $until}, orderBy: [date_DESC]) {
        max { payloadSize }
        dimensions { date }
      }
    }
  }
}`

const r2OpsQuery = `query($accountTag: String!, $since: String!, $until: String!) {
  viewer {
    accounts(filter: {accountTag: $accountTag}) {
      r2OperationsAdaptiveGroups(limit: 1000, filter: {datetime_geq: $since, datetime_leq: $until}) {
        sum { requests }
      }
    }
  }
}`

// pollCloudflare queries Cloudflare's GraphQL Analytics API for today's
// Workers invocation count and this account's current R2 storage/operations
// totals.
func (s *Service) pollCloudflare(ctx context.Context) ([]Metric, error) {
	if s.cfAPIToken == "" || s.cfAccountID == "" {
		return nil, nil
	}

	now := time.Now().UTC()
	todayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	monthStart := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)

	var metrics []Metric

	if v, raw, err := s.workersRequestsToday(ctx, todayStart, now); err != nil {
		slog.Warn("cloudusage: cloudflare workers query failed", "error", err)
	} else {
		metrics = append(metrics, Metric{
			Provider: "cloudflare", MetricKey: "workers_requests_today", Label: "Workers requests (today)",
			UsedValue: v, LimitValue: floatPtr(cfFreeWorkersRequestsPerDay), LimitIsLive: false,
			Unit: "count", Raw: raw,
		})
	}

	if v, raw, err := s.r2StorageCurrent(ctx, now); err != nil {
		slog.Warn("cloudusage: cloudflare r2 storage query failed", "error", err)
	} else {
		metrics = append(metrics, Metric{
			Provider: "cloudflare", MetricKey: "r2_storage_bytes", Label: "R2 storage (current)",
			UsedValue: v, LimitValue: floatPtr(cfFreeR2StorageBytes), LimitIsLive: false,
			Unit: "bytes", Raw: raw,
		})
	}

	if v, raw, err := s.r2OpsThisMonth(ctx, monthStart, now); err != nil {
		slog.Warn("cloudusage: cloudflare r2 ops query failed", "error", err)
	} else {
		metrics = append(metrics, Metric{
			Provider: "cloudflare", MetricKey: "r2_operations_total", Label: "R2 operations (this month)",
			UsedValue: v, LimitValue: floatPtr(cfFreeR2ClassAOpsPerMonth), LimitIsLive: false,
			Unit: "count", Raw: raw,
		})
	}

	return metrics, nil
}

func (s *Service) workersRequestsToday(ctx context.Context, since, until time.Time) (float64, []byte, error) {
	body, err := s.cfGraphQLRaw(ctx, workersQuery, map[string]interface{}{
		"accountTag": s.cfAccountID, "since": since.Format(time.RFC3339), "until": until.Format(time.RFC3339),
	})
	if err != nil {
		return 0, body, err
	}
	var parsed struct {
		Data struct {
			Viewer struct {
				Accounts []struct {
					Groups []struct {
						Sum struct {
							Requests float64 `json:"requests"`
						} `json:"sum"`
					} `json:"workersInvocationsByOwnerAndScriptGroups"`
				} `json:"accounts"`
			} `json:"viewer"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return 0, body, err
	}
	if len(parsed.Data.Viewer.Accounts) == 0 {
		return 0, body, fmt.Errorf("no account data returned")
	}
	var total float64
	for _, g := range parsed.Data.Viewer.Accounts[0].Groups {
		total += g.Sum.Requests
	}
	return total, body, nil
}

func (s *Service) r2StorageCurrent(ctx context.Context, now time.Time) (float64, []byte, error) {
	since := now.Add(-72 * time.Hour).Format("2006-01-02")
	until := now.Format("2006-01-02")
	body, err := s.cfGraphQLRaw(ctx, r2StorageQuery, map[string]interface{}{
		"accountTag": s.cfAccountID, "since": since, "until": until,
	})
	if err != nil {
		return 0, body, err
	}
	var parsed struct {
		Data struct {
			Viewer struct {
				Accounts []struct {
					Groups []struct {
						Max struct {
							PayloadSize float64 `json:"payloadSize"`
						} `json:"max"`
					} `json:"r2StorageAdaptiveGroups"`
				} `json:"accounts"`
			} `json:"viewer"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return 0, body, err
	}
	if len(parsed.Data.Viewer.Accounts) == 0 || len(parsed.Data.Viewer.Accounts[0].Groups) == 0 {
		return 0, body, fmt.Errorf("no r2 storage data returned yet (storage stats can lag by up to a day for a brand-new bucket)")
	}
	return parsed.Data.Viewer.Accounts[0].Groups[0].Max.PayloadSize, body, nil
}

func (s *Service) r2OpsThisMonth(ctx context.Context, since, until time.Time) (float64, []byte, error) {
	body, err := s.cfGraphQLRaw(ctx, r2OpsQuery, map[string]interface{}{
		"accountTag": s.cfAccountID, "since": since.Format(time.RFC3339), "until": until.Format(time.RFC3339),
	})
	if err != nil {
		return 0, body, err
	}
	var parsed struct {
		Data struct {
			Viewer struct {
				Accounts []struct {
					Groups []struct {
						Sum struct {
							Requests float64 `json:"requests"`
						} `json:"sum"`
					} `json:"r2OperationsAdaptiveGroups"`
				} `json:"accounts"`
			} `json:"viewer"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return 0, body, err
	}
	if len(parsed.Data.Viewer.Accounts) == 0 {
		return 0, body, fmt.Errorf("no account data returned")
	}
	var total float64
	for _, g := range parsed.Data.Viewer.Accounts[0].Groups {
		total += g.Sum.Requests
	}
	return total, body, nil
}

func (s *Service) cfGraphQLRaw(ctx context.Context, query string, variables map[string]interface{}) ([]byte, error) {
	payload, err := json.Marshal(map[string]interface{}{"query": query, "variables": variables})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.cloudflare.com/client/v4/graphql", bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+s.cfAPIToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return body, fmt.Errorf("cloudflare graphql returned %d: %s", resp.StatusCode, body)
	}
	var errCheck struct {
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	if err := json.Unmarshal(body, &errCheck); err == nil && len(errCheck.Errors) > 0 {
		return body, fmt.Errorf("cloudflare graphql error: %s", errCheck.Errors[0].Message)
	}
	return body, nil
}
