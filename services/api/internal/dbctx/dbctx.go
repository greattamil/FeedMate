// Package dbctx wraps the PostgreSQL connection pools and enforces that every
// tenant-scoped database operation carries a trusted, server-established tenant
// context (app.tenant_id) for Row-Level Security. No caller may set the tenant
// context from a client-supplied value — it must come from the verified access
// token via the auth middleware.
package dbctx

import (
	"context"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	decimalpgx "github.com/jackc/pgx-shopspring-decimal"
)

// DB holds two genuinely separate connection pools, matching the two
// PostgreSQL roles created in migration 0012:
//   - Pool connects as app_user (NOBYPASSRLS, ordinary tenant-scoped policies
//     only) and is used for every normal request.
//   - AdminPool connects as app_admin and is used ONLY for the narrow,
//     explicitly authorized cross-tenant operations the admin_cross_tenant
//     RLS policies are scoped "TO app_admin" for (tenant onboarding, and
//     resolving which tenant a device belongs to before login). Setting the
//     app.admin_mode session flag has no effect on a connection using the
//     app_user role — the policy is role-scoped, not just flag-scoped — so
//     using the right pool is what actually enforces least privilege here.
type DB struct {
	Pool      *pgxpool.Pool
	AdminPool *pgxpool.Pool
}

// PoolConfig caps how many connections each of the two pools may open.
// pgxpool defaults MaxConns to 4x the host's CPU count when unset, which on
// a 4-core host is 16 connections *per pool* — 32 total between Pool and
// AdminPool, comfortably exceeding a small managed Postgres instance's
// connection budget (Aiven's cheapest tier caps at 20, several of which
// Aiven's own internal processes already hold) on a single API instance
// with no other client connected. Callers must size these to the actual
// database's max_connections, leaving headroom for direct psql access,
// the migrate tool, and the provider's own overhead.
type PoolConfig struct {
	// AppUserMaxConns bounds the pool used for every normal request.
	AppUserMaxConns int32
	// AdminMaxConns bounds the pool used only for the narrow, rare
	// cross-tenant operations WithAdminTx performs — it needs far less
	// headroom than the main traffic pool.
	AdminMaxConns int32
}

// DefaultPoolConfig is deliberately conservative rather than derived from
// the host's CPU count, since the constraint here is the database's
// connection budget, not the API host's compute.
func DefaultPoolConfig() PoolConfig {
	return PoolConfig{AppUserMaxConns: 8, AdminMaxConns: 3}
}

func Connect(ctx context.Context, appUserURL, adminURL string) (*DB, error) {
	return ConnectWithPoolConfig(ctx, appUserURL, adminURL, DefaultPoolConfig())
}

func ConnectWithPoolConfig(ctx context.Context, appUserURL, adminURL string, cfg PoolConfig) (*DB, error) {
	pool, err := newPool(ctx, appUserURL, cfg.AppUserMaxConns)
	if err != nil {
		return nil, fmt.Errorf("connect app_user pool: %w", err)
	}
	adminPool, err := newPool(ctx, adminURL, cfg.AdminMaxConns)
	if err != nil {
		pool.Close()
		return nil, fmt.Errorf("connect app_admin pool: %w", err)
	}
	return &DB{Pool: pool, AdminPool: adminPool}, nil
}

func newPool(ctx context.Context, url string, maxConns int32) (*pgxpool.Pool, error) {
	poolCfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, fmt.Errorf("parse database url: %w", err)
	}
	if maxConns > 0 {
		poolCfg.MaxConns = maxConns
	}
	// Register shopspring/decimal <-> PostgreSQL NUMERIC codec on every
	// connection so money/quantity values round-trip as decimal.Decimal —
	// never as float32/float64 — per the mandatory numeric precision rules.
	poolCfg.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
		decimalpgx.Register(conn.TypeMap())
		return nil
	}
	pool, err := pgxpool.NewWithConfig(ctx, poolCfg)
	if err != nil {
		return nil, fmt.Errorf("connect to database: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping database: %w", err)
	}
	return pool, nil
}

func (d *DB) Close() {
	d.Pool.Close()
	d.AdminPool.Close()
}

// WithTenantTx runs fn inside a single database transaction on the app_user
// pool with the PostgreSQL session variable app.tenant_id set for the lifetime
// of that transaction only (the `true` "is_local" flag on set_config), so RLS
// policies enforce isolation. The transaction commits only if fn returns nil.
func (d *DB) WithTenantTx(ctx context.Context, tenantID uuid.UUID, fn func(tx pgx.Tx) error) error {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tenantID.String()); err != nil {
		return fmt.Errorf("set tenant context: %w", err)
	}

	if err := fn(tx); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit transaction: %w", err)
	}
	return nil
}

// WithAdminTx runs fn inside a transaction on the app_admin pool with
// app.admin_mode='on', the only sanctioned path for cross-tenant
// administrative operations (tenant onboarding, resolving a device's tenant
// at login, support tooling). Callers must independently authorize the
// caller for this before invoking it — this function performs no
// authorization itself, and every call site must be narrowly scoped and
// reviewed, since it can see across all tenants.
func (d *DB) WithAdminTx(ctx context.Context, fn func(tx pgx.Tx) error) error {
	tx, err := d.AdminPool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, `SELECT set_config('app.admin_mode', 'on', true)`); err != nil {
		return fmt.Errorf("set admin mode: %w", err)
	}

	if err := fn(tx); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit transaction: %w", err)
	}
	return nil
}

// WithTenantReadTx is a convenience wrapper for read-only tenant-scoped queries
// that do not need explicit transaction control from the caller.
func (d *DB) WithTenantReadTx(ctx context.Context, tenantID uuid.UUID, fn func(tx pgx.Tx) error) error {
	return d.WithTenantTx(ctx, tenantID, fn)
}
