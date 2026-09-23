// Package config loads runtime configuration from the environment.
// No secret ever has a hard-coded production value here — only safe local defaults
// that are unmistakably unsuitable for production (e.g. "dev_only_change_me").
package config

import (
	"fmt"
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
	PaymentProvider       string
	SandboxWebhookSecret  string
}

func Load() (Config, error) {
	cfg := Config{
		AppEnv:               getEnv("APP_ENV", "development"),
		HTTPAddr:             resolveHTTPAddr(),
		DatabaseURL:          os.Getenv("DATABASE_URL"),
		DatabaseAdminURL:     os.Getenv("DATABASE_ADMIN_URL"),
		DBPoolMaxConns:       int32(getInt("DB_POOL_MAX_CONNS", 8)),
		DBAdminPoolMaxConns:  int32(getInt("DB_ADMIN_POOL_MAX_CONNS", 3)),
		RedisURL:             os.Getenv("REDIS_URL"),
		JWTSigningKey:        os.Getenv("JWT_SIGNING_KEY"),
		AccessTokenTTL:       getDuration("ACCESS_TOKEN_TTL", 15*time.Minute),
		RefreshTokenTTL:      getDuration("REFRESH_TOKEN_TTL", 30*24*time.Hour),
		BcryptCost:           getInt("BCRYPT_COST", 12),
		AdminAPIEnabled:      getBool("ADMIN_API_ENABLED", false),
		IdempotencyRetention: getDuration("IDEMPOTENCY_RETENTION", 7*24*time.Hour),
		PaymentProvider:      getEnv("PAYMENT_PROVIDER", "sandbox"),
		SandboxWebhookSecret: os.Getenv("SANDBOX_WEBHOOK_SECRET"),
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
