// Package config loads runtime configuration from the environment.
// No secret ever has a hard-coded production value here — only safe local defaults
// that are unmistakably unsuitable for production (e.g. "dev_only_change_me").
package config

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"time"
)

type Config struct {
	AppEnv   string
	HTTPAddr string

	DatabaseURL      string
	DatabaseAdminURL string
	// DBPoolMaxConns/DBAdminPoolMaxConns bound the two connection pools —
	// see dbctx.PoolConfig's doc comment for why these must be sized to the
	// database's actual connection budget, not the API host's CPU count.
	DBPoolMaxConns      int32
	DBAdminPoolMaxConns int32

	RedisURL string

	JWTSigningKey        string
	AccessTokenTTL       time.Duration
	RefreshTokenTTL      time.Duration
	BcryptCost           int
	AdminAPIEnabled      bool
	IdempotencyRetention time.Duration

	// PaymentProvider selects which paymentprovider.Provider implementation
	// is wired up. Only "sandbox" is implemented today — production gateway
	// credentials (Razorpay/Cashfree/PhonePe/etc.) are not available in this
	// environment; see internal/paymentprovider for the interface a real
	// provider must implement to be swapped in.
	PaymentProvider      string
	SandboxWebhookSecret string

	// CloudUsage* configure the platform-admin live usage dashboard
	// (internal/domain/cloudusage). Each provider's credentials are
	// optional and independent — if one is unset, that provider's
	// metrics are simply omitted from the poll rather than erroring,
	// since this feature must not block API startup.
	CloudflareAPIToken     string
	CloudflareAccountID    string
	GCPProjectID           string
	AivenAPIToken          string
	AivenProject           string
	AivenService           string
	CloudUsagePollInterval time.Duration

	// FirebaseProjectID enables pushnotify (FCM push notifications) —
	// optional, same "feature just skipped if unset" convention as the
	// CloudUsage fields above. In practice the same value as
	// GCPProjectID, since Firebase is added to the existing GCP project
	// rather than a separate one.
	FirebaseProjectID string

	// GCPRegion/DBBackupJobName locate the feedmate-db-backup Cloud Run Job
	// that TriggerDBBackup kicks off (see internal/domain/dbbackup) —
	// defaults match deploy/gcp/deploy-db-backup.sh's own defaults, only
	// need overriding on a genuinely different environment.
	GCPRegion       string
	DBBackupJobName string

	// EdgeSharedSecret, when set, requires every request to carry a
	// matching X-Edge-Secret header (see middleware.RequireEdgeSecret) —
	// blocks direct traffic to Cloud Run's public *.run.app URL that
	// bypasses the Cloudflare Worker proxy entirely.
	EdgeSharedSecret string

	// CronSecret gates /internal/cron/* (see httpapi.CronHandlers):
	// Google Cloud Scheduler calls these with X-Cron-Secret set to this
	// value to trigger the billing cycle and cloud-usage poll on
	// Cloud Run, where the in-process ticker (EnableInProcessScheduler)
	// isn't reliable — see cron_handlers.go's doc comment for why.
	CronSecret string

	// PublicWebsiteTenantID pins the public, unauthenticated catalog
	// endpoint (GET /api/v1/public/catalog — see httpapi.PublicHandlers)
	// to exactly one tenant, read from server config rather than any
	// request input, so a website visitor can never choose whose catalog
	// they see. Empty disables the endpoint (503) rather than guessing —
	// see PublicHandlers.GetPublicCatalog. Not a secret: a tenant UUID
	// reveals nothing sensitive on its own.
	PublicWebsiteTenantID string

	// ProductImagesUploadSecret authenticates the API's writes to the
	// product-images Worker (deploy/cloudflare/product-images/) — see
	// httpapi.UploadProductImage. Must match that Worker's own
	// UPLOAD_SECRET, set via `wrangler secret put UPLOAD_SECRET` from its
	// directory. A genuine secret (unlike PublicWebsiteTenantID above),
	// so it follows the appSecrets fallback pattern like every other one.
	ProductImagesUploadSecret string
	// ProductImagesBaseURL is the product-images Worker's public base URL
	// (e.g. https://images.bpkscattlefeeds.com) — not hardcoded, same
	// "every account-specific value is an env var" convention as
	// deploy/gcp/deploy-api.sh's own header comment.
	ProductImagesBaseURL string

	// EnableInProcessScheduler controls whether the in-process ticker
	// goroutines (subscription.StartBillingScheduler,
	// cloudusage.StartUsagePollScheduler) run at all. Default true — the
	// right choice for self-hosted/VPS deployments (docker-compose.prod.yml),
	// where the process runs continuously and the ticker is reliable.
	// The Cloud Run deploy sets this to false (via deploy/gcp/deploy-api.sh)
	// since there Google Cloud Scheduler drives the same work instead, and
	// a ticker that silently never fires while idle is pointless to run.
	EnableInProcessScheduler bool
}

// loadJSONSecretFile reads a small JSON object (e.g. {"url": "...",
// "admin_url": "..."}) from the file at path, used by dbCredentialsFile /
// internalSecretsFile below to let several related secrets share one
// Secret Manager entry — see those two vars' doc comment for why. Absent
// path or unreadable/malformed file both just return an empty map rather
// than erroring, so local/VPS dev (which sets the individual env vars
// directly, no file involved) is unaffected.
func loadJSONSecretFile(path string) map[string]string {
	out := map[string]string{}
	if path == "" {
		return out
	}
	data, err := os.ReadFile(path)
	if err != nil {
		slog.Error("config: failed to read JSON secret file", "path", path, "error", err)
		return out
	}
	if err := json.Unmarshal(data, &out); err != nil {
		slog.Error("config: failed to parse JSON secret file", "path", path, "error", err)
	}
	return out
}

func Load() (Config, error) {
	// appSecrets: on Cloud Run, APP_SECRETS_FILE points at a single JSON
	// secret (Secret Manager entry "app-secrets") mounted as a file,
	// holding every production secret this service needs as one object
	// — database_url, database_admin_url, jwt_signing_key,
	// sandbox_webhook_secret, edge_secret, cron_secret,
	// cloudflare_api_token, aiven_api_token. One secret, one active
	// version, instead of six separate Secret Manager entries (the
	// previous design) — simpler to rotate/audit, and leaves maximum
	// headroom under Secret Manager's free tier of 6 active versions/
	// account rather than sitting right at the line. Each individual env
	// var below (DATABASE_URL, etc.) still wins if set directly, which
	// is what local dev and the self-hosted/VPS docker-compose path do —
	// no file involved there.
	appSecrets := loadJSONSecretFile(os.Getenv("APP_SECRETS_FILE"))

	cfg := Config{
		AppEnv:               getEnv("APP_ENV", "development"),
		HTTPAddr:             resolveHTTPAddr(),
		DatabaseURL:          firstNonEmpty(os.Getenv("DATABASE_URL"), appSecrets["database_url"]),
		DatabaseAdminURL:     firstNonEmpty(os.Getenv("DATABASE_ADMIN_URL"), appSecrets["database_admin_url"]),
		DBPoolMaxConns:       int32(getInt("DB_POOL_MAX_CONNS", 8)),
		DBAdminPoolMaxConns:  int32(getInt("DB_ADMIN_POOL_MAX_CONNS", 3)),
		RedisURL:             os.Getenv("REDIS_URL"),
		JWTSigningKey:        firstNonEmpty(os.Getenv("JWT_SIGNING_KEY"), appSecrets["jwt_signing_key"]),
		AccessTokenTTL:       getDuration("ACCESS_TOKEN_TTL", 15*time.Minute),
		RefreshTokenTTL:      getDuration("REFRESH_TOKEN_TTL", 30*24*time.Hour),
		BcryptCost:           getInt("BCRYPT_COST", 12),
		AdminAPIEnabled:      getBool("ADMIN_API_ENABLED", false),
		IdempotencyRetention: getDuration("IDEMPOTENCY_RETENTION", 7*24*time.Hour),
		PaymentProvider:      getEnv("PAYMENT_PROVIDER", "sandbox"),
		SandboxWebhookSecret: firstNonEmpty(os.Getenv("SANDBOX_WEBHOOK_SECRET"), appSecrets["sandbox_webhook_secret"]),

		CloudflareAPIToken:     firstNonEmpty(os.Getenv("CLOUDFLARE_API_TOKEN"), appSecrets["cloudflare_api_token"]),
		CloudflareAccountID:    os.Getenv("CLOUDFLARE_ACCOUNT_ID"),
		GCPProjectID:           os.Getenv("GCP_PROJECT_ID"),
		AivenAPIToken:          firstNonEmpty(os.Getenv("AIVEN_API_TOKEN"), appSecrets["aiven_api_token"]),
		AivenProject:           os.Getenv("AIVEN_PROJECT"),
		AivenService:           os.Getenv("AIVEN_SERVICE"),
		CloudUsagePollInterval: getDuration("CLOUD_USAGE_POLL_INTERVAL", 1*time.Hour),
		FirebaseProjectID:      os.Getenv("FIREBASE_PROJECT_ID"),
		GCPRegion:              getEnv("GCP_REGION", "asia-south1"),
		DBBackupJobName:        getEnv("DB_BACKUP_JOB_NAME", "feedmate-db-backup"),
		EdgeSharedSecret:       firstNonEmpty(os.Getenv("EDGE_SHARED_SECRET"), appSecrets["edge_secret"]),

		CronSecret:               firstNonEmpty(os.Getenv("CRON_SECRET"), appSecrets["cron_secret"]),
		PublicWebsiteTenantID:    os.Getenv("PUBLIC_WEBSITE_TENANT_ID"),
		ProductImagesUploadSecret: firstNonEmpty(os.Getenv("PRODUCT_IMAGES_UPLOAD_SECRET"), appSecrets["product_images_upload_secret"]),
		ProductImagesBaseURL:      os.Getenv("PRODUCT_IMAGES_BASE_URL"),
		EnableInProcessScheduler: getBool("ENABLE_IN_PROCESS_SCHEDULER", true),
	}

	if cfg.DatabaseURL == "" {
		return cfg, fmt.Errorf("DATABASE_URL is required")
	}
	if cfg.DatabaseAdminURL == "" {
		return cfg, fmt.Errorf("DATABASE_ADMIN_URL is required (must connect as the app_admin role)")
	}
	if cfg.JWTSigningKey == "" {
		if cfg.AppEnv == "production" {
			return cfg, fmt.Errorf("JWT_SIGNING_KEY is required in production")
		}
		cfg.JWTSigningKey = "dev_only_change_me"
	}
	if cfg.SandboxWebhookSecret == "" {
		if cfg.AppEnv == "production" {
			return cfg, fmt.Errorf("SANDBOX_WEBHOOK_SECRET is required (or configure a real PAYMENT_PROVIDER before production)")
		}
		cfg.SandboxWebhookSecret = "dev_only_change_me"
	}
	return cfg, nil
}

// resolveHTTPAddr prefers Cloud Run's PORT convention (the platform injects
// this at runtime and requires the container to bind to it, regardless of
// anything baked into the image) over HTTP_ADDR, which stays the way to
// configure the port for every other deployment target (docker-compose,
// local dev) where PORT is never set.
func resolveHTTPAddr() string {
	if port := os.Getenv("PORT"); port != "" {
		return ":" + port
	}
	return getEnv("HTTP_ADDR", ":8080")
}

// firstNonEmpty returns primary if set, else fallback — used to let the
// plain env var win over the JSON-secret-file value when both are present.
func firstNonEmpty(primary, fallback string) string {
	if primary != "" {
		return primary
	}
	return fallback
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func getBool(key string, def bool) bool {
	if v := os.Getenv(key); v != "" {
		if b, err := strconv.ParseBool(v); err == nil {
			return b
		}
	}
	return def
}

func getDuration(key string, def time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}
