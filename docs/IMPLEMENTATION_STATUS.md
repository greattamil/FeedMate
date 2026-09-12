# Andipatti Animal Feed System — Implementation Status

Last updated: 2026-09-12 (session 2)

This is a large, multi-module production system (offline-first Flutter POS,
Go backend, PostgreSQL with RLS, payments, GST/compliance, hardware, sync,
accounting, reporting, backup/DR). It is being built incrementally across
sessions. This document tracks real, verified status — nothing below is
marked VERIFIED unless it was actually executed against running
infrastructure in this repository.

Legend: `NOT_STARTED` / `IN_PROGRESS` / `IMPLEMENTED` / `TESTED` / `VERIFIED`

## Phase 1 — Database Foundation

| Area | Status | Evidence |
|---|---|---|
| Repo/monorepo structure | IMPLEMENTED | `apps/`, `services/`, `db/`, `integrations/`, `deploy/`, `tests/` scaffolded |
| Core schema migrations (13 files, ~75 tables) | VERIFIED | Applied cleanly to a fresh PostgreSQL 16 container via `golang-migrate`; see `db/migrations/` |
| Tenant/financial-year/document-series model | IMPLEMENTED | `db/migrations/0001_extensions_and_tenant.up.sql` |
| Identity/RBAC/devices | IMPLEMENTED | `db/migrations/0002_identity_rbac.up.sql`; 32 system permission codes seeded |
| Product/UOM/tax/pricing | IMPLEMENTED | `db/migrations/0003_product_uom_tax_pricing.up.sql` |
| Customer/Khata ledger, supplier ledger | IMPLEMENTED | `db/migrations/0004_customer_supplier.up.sql` |
| Procurement (PO/GRN with tare fields) | IMPLEMENTED | `db/migrations/0005_locations_procurement.up.sql` |
| Inventory ledger, batches, stock counts | IMPLEMENTED | `db/migrations/0006_inventory_batches.up.sql` |
| Sales/POS (invoices, tax lines, batch allocation, tenders, returns) | IMPLEMENTED | `db/migrations/0007_sales_pos.up.sql` |
| Payments (intents, webhooks, refunds) | IMPLEMENTED | `db/migrations/0008_payments.up.sql` |
| Accounting journal (with DB-enforced debit=credit trigger), contra, cash/EOD | IMPLEMENTED | `db/migrations/0009_accounting_contra_cash.up.sql` |
| Notifications, offline sync tables | IMPLEMENTED | `db/migrations/0010_notifications_sync.up.sql` |
| Compliance, archive, audit, outbox | IMPLEMENTED | `db/migrations/0011_compliance_archive_audit.up.sql` |
| **PostgreSQL Row-Level Security on every tenant-owned table** | **VERIFIED** | `db/migrations/0012_rls_policies.up.sql`; automated test suite `tests/security/rls_isolation_test.sql` run via `scripts/test-rls.sh` — passed: fail-closed with no context, tenant sees only own rows, cross-tenant INSERT/UPDATE/DELETE all denied |
| Global reference data seed (UOMs) | IMPLEMENTED | `db/migrations/0013_seed_reference_data.up.sql` |
| Docker Compose dev environment (Postgres, Redis, migrate, api/worker stubs) | IMPLEMENTED | `deploy/compose/docker-compose.yml` — Postgres+Redis verified running and healthy |

### Real bugs found and fixed during this session (not hypothetical)
- Several composite-FK parent tables (`goods_receipt_lines`, `stock_counts`,
  `sales_return_lines`, `message_templates`, `notification_jobs`,
  `sync_transactions`) were missing the `UNIQUE(tenant_id, id)` constraint
  required for child tables to reference them via `(tenant_id, parent_id)`
  composite foreign keys. Caught by actually running the migrations against
  Postgres, not by inspection.
- The `tenants` table was silently excluded from the admin cross-tenant
  bypass policy because the generic policy-generation loop only matches
  tables with a `tenant_id` column, and `tenants` has none (it uses `id`).
  A dedicated `admin_cross_tenant` policy was added for `tenants`
  specifically. Caught by actually attempting tenant creation as `app_admin`
  and observing the RLS denial.

## Phase 2 — Go Backend Foundation (Auth, Tenant Context, RBAC)

| Area | Status | Evidence |
|---|---|---|
| Go module scaffold (`services/api`) | IMPLEMENTED | chi router, pgx/pgxpool, JWT, bcrypt, shopspring/decimal wired in |
| Dual-role DB connection model (app_user pool + separate app_admin pool) | **VERIFIED** | `internal/dbctx/dbctx.go`; see bug #3 below — this was fixed after testing exposed that a single-role pool cannot use the admin bypass at all |
| Password hashing (bcrypt) + refresh-token hashing | IMPLEMENTED | `internal/auth/password.go`, `internal/auth/jwt.go` |
| JWT access tokens carrying trusted tenant/user/device/permissions | IMPLEMENTED | `internal/auth/jwt.go` |
| Login (device→tenant resolution, credential check, lockout, session issuance) | **VERIFIED** | `internal/domain/identity/service.go`; exercised via real HTTP calls against the live dev DB and via automated Go integration test `service_integration_test.go` |
| Refresh token rotation (old token invalidated on use) | **VERIFIED** | Integration test confirms reuse of a rotated token is rejected |
| Logout / session revocation | **VERIFIED** | Integration test confirms refresh fails after logout |
| Standardized API error envelope (code/message/request_id/retryable) | IMPLEMENTED | `internal/httpapi/errors.go`, matches PRD A21 |
| Request ID propagation, panic recovery, bearer-auth middleware, permission-check middleware | IMPLEMENTED | `internal/middleware/middleware.go` |
| Health endpoints (`/health/live`, `/health/ready`) | **VERIFIED** | Hit via curl against a running server; `/health/ready` genuinely pings the DB pool |
| Automated integration test suite for identity/auth | **VERIFIED** | `internal/domain/identity/service_integration_test.go`, runnable via `scripts/test-integration.sh` |

### Real bugs found and fixed this session (not hypothetical)
1. **Import cycle** between `middleware` and `httpapi` packages (each needed the request ID from the other) — resolved by extracting a small shared `internal/reqctx` package. Caught by `go build`.
2. **Composite FK gaps** in three more tables discovered while re-verifying migrations were still fully self-consistent (see Phase 1 section).
3. **Admin bypass was silently non-functional**: `WithAdminTx` set the `app.admin_mode` session flag, but the connection pool it ran on connected as `app_user`, and the `admin_cross_tenant` RLS policies are scoped `TO app_admin` only — so the flag had no effect and the very first cross-tenant admin operation (resolving a login device's tenant) failed. Fixed by giving `dbctx.DB` two genuinely separate pools (`Pool` for `app_user`, `AdminPool` for `app_admin`) and routing `WithAdminTx` to the admin pool. Caught by actually attempting a login through the HTTP API, not by inspection.
4. **Critical RLS correctness bug, found only by an automated integration test, not manual curl testing**: PostgreSQL custom GUCs (`app.tenant_id`) are placeholder variables — once *any* transaction on a pooled physical connection sets one locally, `current_setting(..., true)` reverts to an **empty string**, not `NULL`, after that transaction ends (confirmed empirically). Because pgxpool reuses connections across unrelated transactions, any connection that had ever served a tenant-scoped request would thereafter throw a hard `invalid input syntax for type uuid: ""` error on the next admin-mode query on that same connection that didn't set `app.tenant_id` — e.g. the device-resolution step of login. This is now fixed in `db/migrations/0014_rls_tenant_context_fix.up.sql` by wrapping every RLS policy's `current_setting(...)::uuid` cast in `NULLIF(..., '')` so "never set" and "reset to empty" both fail closed safely instead of erroring. The RLS isolation test suite (`tests/security/rls_isolation_test.sql`) was re-run and still passes after the fix, and the identity integration test — which had been failing with exactly this error — now passes in full. This is exactly the class of bug the master spec's testing requirements exist to catch, and it would not have been found without writing and running (not just writing) an automated test against a real, connection-pooled database.

## Not Yet Started

Business domain modules (products, inventory, procurement, POS/invoice
finalization, Khata/accounting, payments, contra, EOD, reports),
idempotency/outbox infrastructure, Flutter app (offline-first, SQLCipher,
POS UI), payment/GST/WhatsApp provider adapters, hardware adapters
(scale/printer/scanner), seed/config workflows, CI/CD, the rest of the test
suites (E2E/offline/chaos/load), backup/DR tooling, and the remaining
documentation set. These will be built in subsequent sessions, in the
priority order set by the master specification (security → financial
integrity → tenant isolation → inventory → payments → compliance → offline
sync → API → backend → Flutter → hardware → UI → reporting → DevOps).

## Production Readiness

**NOT READY.** The database foundation and the auth/identity vertical slice
of the Go backend exist and have been verified end-to-end (real HTTP calls
and automated integration tests against a live PostgreSQL instance). No
business domain logic (POS, inventory, payments, accounting), no client
application, no third-party integrations, and no CI exist yet.
