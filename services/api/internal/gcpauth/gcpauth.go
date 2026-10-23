// Package gcpauth fetches an OAuth2 access token from the Cloud Run
// instance's own metadata server — Application Default Credentials, no
// service-account key ever stored anywhere. The token carries whatever
// permissions are IAM-granted to the Cloud Run service's runtime service
// account (794548234279-compute@developer.gserviceaccount.com by default);
// which specific Google APIs a caller can actually use is controlled by
// IAM role bindings (see deploy/gcp/deploy-api.sh), not by anything
// requested here.
//
// Originally lived only inside cloudusage/poller_gcp.go for Cloud
// Monitoring calls; extracted here so pushnotify can reuse the exact same
// mechanism for Firebase Cloud Messaging instead of minting a second
// credential path.
package gcpauth

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

// FetchToken retrieves a fresh access token from the metadata server. No
// caching — each call means one fast local HTTP request to the metadata
// server (not a real network hop), and tokens expire, so callers that need
// one just ask again rather than tracking expiry themselves.
func FetchToken(ctx context.Context, client *http.Client) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token", nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Metadata-Flavor", "Google")
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("metadata server returned %d: %s", resp.StatusCode, body)
	}
	var out struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return "", err
	}
	return out.AccessToken, nil
}
