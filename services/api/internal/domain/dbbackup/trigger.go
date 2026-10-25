// Package dbbackup triggers the feedmate-db-backup Cloud Run Job on
// demand. The job itself still runs on Cloud Run (per deploy/backup/ —
// deliberately kept there rather than rewritten as a Cloudflare Worker,
// since Workers can't run pg_dump), but scheduling moved to a Cloudflare
// Worker Cron Trigger (deploy/cloudflare/db-backup/) to get the daily
// kickoff off Google Cloud Scheduler entirely — see that Worker's
// comments for why. This package is what the Worker's cron tick actually
// calls into, via CronHandlers.TriggerDBBackup.
package dbbackup

import (
	"context"
	"fmt"
	"io"
	"net/http"

	"github.com/andipatti/feedmate/services/api/internal/gcpauth"
)

type Trigger struct {
	HTTPClient *http.Client
	ProjectID  string
	Region     string
	JobName    string
}

// Run calls the Cloud Run Admin API's jobs.run, same ambient-credentials
// mechanism gcpauth already uses for Cloud Monitoring and Firebase
// Messaging — no service-account key, just the IAM role
// deploy/gcp/deploy-db-backup.sh grants this service's own runtime
// identity (roles/run.invoker on the feedmate-db-backup Job).
func (t *Trigger) Run(ctx context.Context) error {
	token, err := gcpauth.FetchToken(ctx, t.HTTPClient)
	if err != nil {
		return fmt.Errorf("fetch token: %w", err)
	}
	url := fmt.Sprintf("https://run.googleapis.com/v2/projects/%s/locations/%s/jobs/%s:run", t.ProjectID, t.Region, t.JobName)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := t.HTTPClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("cloud run jobs:run returned %d: %s", resp.StatusCode, body)
	}
	return nil
}
