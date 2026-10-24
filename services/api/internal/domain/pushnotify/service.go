// Package pushnotify sends Firebase Cloud Messaging (FCM) push
// notifications to a tenant's registered Android devices. Authenticates
// via gcpauth (the same Cloud Run metadata-server ADC mechanism
// internal/domain/cloudusage uses for Cloud Monitoring) — no
// service-account key is stored anywhere; the Cloud Run runtime service
// account just needs the Firebase Cloud Messaging send IAM role (see
// deploy/gcp/deploy-api.sh).
//
// FCM itself is a genuinely free product regardless of Firebase plan
// (Spark/free is sufficient — confirmed against Firebase's own pricing
// page during planning) as long as sending happens from your own server,
// not Cloud Functions. This package calls the FCM HTTP v1 REST API
// directly from the existing Cloud Run container, so no Firebase SDK
// dependency and no new billable surface.
package pushnotify

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/gcpauth"
)

type Service struct {
	db           *dbctx.DB
	httpClient   *http.Client
	gcpProjectID string
}

func NewService(db *dbctx.DB, gcpProjectID string) *Service {
	return &Service{
		db:           db,
		httpClient:   &http.Client{Timeout: 10 * time.Second},
		gcpProjectID: gcpProjectID,
	}
}

// SetDeviceToken stores (or clears, if token is empty — e.g. on logout)
// the calling device's current FCM registration token. Scoped to one
// device by ID, never trusts a caller-supplied device_uuid — same
// "a device can only ever speak for itself" convention as everywhere else
// a device ID comes from JWT claims, not the request body.
func (s *Service) SetDeviceToken(ctx context.Context, tenantID, deviceID uuid.UUID, token string) error {
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `
			UPDATE devices SET fcm_token = $2, fcm_token_updated_at = now() WHERE id = $1
		`, deviceID, nullIfEmpty(token))
		return err
	})
}

func nullIfEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// RichMessage is a push with deep-link data and an Android notification
// channel, on top of the plain title/body every message has. ChannelID
// must match a channel the Flutter client creates at startup (see
// lib/core/notification_service.dart) — an unknown channel ID just falls
// back to Android's default channel rather than failing the send.
type RichMessage struct {
	Title     string
	Body      string
	Data      map[string]string
	ChannelID string
}

// SendToTenant pushes the same title/body to every ACTIVE device the
// tenant has that's registered a token. Best-effort per device — one
// device's failure (a stale/unregistered token, a transient FCM error) is
// logged and skipped, never blocks the others, matching
// cloudusage.PollAll's "one provider failing never blocks the rest"
// convention. Returns how many sends succeeded.
func (s *Service) SendToTenant(ctx context.Context, tenantID uuid.UUID, title, body string) (int, error) {
	return s.SendToTenantRich(ctx, tenantID, RichMessage{Title: title, Body: body})
}

// SendToTenantRich is SendToTenant with a deep-link data payload and a
// notification channel — every event in internal/domain/notify goes
// through this; SendToTenant is now just a thin convenience wrapper for
// plain title/body callers.
func (s *Service) SendToTenantRich(ctx context.Context, tenantID uuid.UUID, msg RichMessage) (int, error) {
	if s.gcpProjectID == "" {
		return 0, nil
	}

	var tokens []string
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT fcm_token FROM devices
			WHERE status = 'ACTIVE' AND fcm_token IS NOT NULL
		`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var t string
			if err := rows.Scan(&t); err != nil {
				return err
			}
			tokens = append(tokens, t)
		}
		return rows.Err()
	})
	if err != nil {
		return 0, fmt.Errorf("list device tokens: %w", err)
	}
	if len(tokens) == 0 {
		return 0, nil
	}

	accessToken, err := gcpauth.FetchToken(ctx, s.httpClient)
	if err != nil {
		return 0, fmt.Errorf("fetch gcp token: %w", err)
	}

	sent := 0
	for _, token := range tokens {
		if err := s.sendOne(ctx, accessToken, token, msg); err != nil {
			slog.Warn("pushnotify: send failed", "error", err)
			continue
		}
		sent++
	}
	return sent, nil
}

func (s *Service) sendOne(ctx context.Context, accessToken, deviceToken string, msg RichMessage) error {
	message := map[string]interface{}{
		"token": deviceToken,
		"notification": map[string]string{
			"title": msg.Title,
			"body":  msg.Body,
		},
	}
	if len(msg.Data) > 0 {
		message["data"] = msg.Data
	}
	if msg.ChannelID != "" {
		message["android"] = map[string]interface{}{
			"priority": "high",
			"notification": map[string]string{
				"channel_id": msg.ChannelID,
				"sound":      "default",
			},
		}
	}
	payload := map[string]interface{}{"message": message}
	raw, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	url := fmt.Sprintf("https://fcm.googleapis.com/v1/projects/%s/messages:send", s.gcpProjectID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("fcm send returned %d: %s", resp.StatusCode, respBody)
	}
	return nil
}
