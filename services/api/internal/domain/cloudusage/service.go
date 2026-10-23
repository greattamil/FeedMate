// Package cloudusage polls the live usage APIs of the three free-tier
// providers this app runs on — Google Cloud Run, Cloudflare (Pages/R2/
// Workers), and Aiven Postgres — and surfaces how close each is to its
// ceiling, so a repeat of the "ran out of money on the old host" situation
// can be caught before it happens rather than discovered after a bill
// arrives.
//
// Every usage number here is fetched live from the provider at poll time —
// nothing is a hardcoded estimate. The one unavoidable exception is Google
// Cloud Run's free-tier *limit* values (2,000,000 requests/month, etc.):
// Google does not expose these ceilings via any API, so they are recorded
// as published constants (see limitIsLive on each snapshot) rather than
// pretended to be live.
package cloudusage

import (
	"net/http"
	"time"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
)

type Service struct {
	db         *dbctx.DB
	httpClient *http.Client

	cfAPIToken  string
	cfAccountID string

	gcpProjectID string

	aivenAPIToken string
	aivenProject  string
	aivenService  string
}

func NewService(db *dbctx.DB, cfAPIToken, cfAccountID, gcpProjectID, aivenAPIToken, aivenProject, aivenService string) *Service {
	return &Service{
		db:         db,
		httpClient: &http.Client{Timeout: 15 * time.Second},

		cfAPIToken:  cfAPIToken,
		cfAccountID: cfAccountID,

		gcpProjectID: gcpProjectID,

		aivenAPIToken: aivenAPIToken,
		aivenProject:  aivenProject,
		aivenService:  aivenService,
	}
}

// Metric is one provider/metric's current reading, ready to persist as a
// cloud_usage_snapshots row.
type Metric struct {
	Provider    string
	MetricKey   string
	Label       string
	UsedValue   float64
	LimitValue  *float64
	LimitIsLive bool
	Unit        string
	Raw         []byte
}

func floatPtr(v float64) *float64 { return &v }
