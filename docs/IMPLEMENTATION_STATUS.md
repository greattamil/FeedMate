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

## Phase 3 — Product Master & Tamil/Phonetic Search

| Area | Status | Evidence |
|---|---|---|
| Product create (with barcodes + aliases) | **VERIFIED** | `internal/domain/product`; exercised via HTTP against the live dev DB and via `service_integration_test.go` |
| Decimal-safe money/quantity fields end-to-end | **VERIFIED** | shopspring/decimal registered as the pgx NUMERIC codec (`internal/dbctx/dbctx.go`); no float32/float64 anywhere in the product domain |
| Tamil Unicode round-trip (Flutter→JSON→Go→PostgreSQL→JSON) | **VERIFIED** | Confirmed byte-exact and codepoint-exact round-trip of a real Tamil string through the full HTTP→DB→HTTP path — this is PRD acceptance test A8 |
| Barcode / SKU / exact-name / alias / fuzzy search ranking (PRD A4) | **VERIFIED** | All five match types tested individually against the live DB and covered by `service_integration_test.go` |
| Alias normalization (Unicode/whitespace/punctuation) | IMPLEMENTED | `product.NormalizeAliasText` |

### Real bugs found and fixed this session (Phase 3)
5. **`Create()` returned Go zero-values for server-defaulted columns**: the INSERT only had `RETURNING id`, so the in-memory `Product` struct's `Active` field stayed `false` (Go's zero value) even though the database correctly stored `true`. The HTTP response told the caller a newly created, active product was inactive. Fixed by returning and scanning `active` (and documented the general rule: scan back every server-defaulted column, not just the generated id). Caught by comparing the HTTP response against a direct DB query, then locked in with a test assertion.
6. **Exact SKU/barcode search was completely broken**: the alias-oriented normalization (which strips punctuation to make colloquial Tamil terms match regardless of spacing) was being applied to the search query before matching against SKU and barcode too — so a query for `CF-50KG-002` was normalized to `cf50kg002`, which never matches the real SKU containing hyphens. Fixed by matching SKU/barcode against the raw (trimmed-only) query and reserving normalization for name/alias/fuzzy matching. This is exactly the kind of defect the master spec's "never silently guess among ambiguous matches" principle is meant to prevent — an operator relying on SKU search at POS would have found nothing. Caught by testing the search endpoint directly, not by code review, and now covered by a permanent regression test (`exact SKU match is found despite hyphens`).

Also confirmed during this phase: an apparently garbled Tamil string in a terminal-printed curl response turned out to be a Windows console codepage display artifact, not a real bug — verified by reading the response bytes directly in a script and comparing codepoints, which matched exactly. Worth recording so a future session doesn't mistake this class of terminal artifact for a real encoding bug.

## Phase 4 — Inventory Ledger, Accounting Journal & POS Invoice Finalization

This is the highest-risk transaction in the whole system (PRD A10: invoice
finalization, stock movements, batch allocation, tender validation, customer
ledger, and the accounting journal must all commit atomically or not at all),
so it received the heaviest testing of any module so far.

| Area | Status | Evidence |
|---|---|---|
| Stock ledger (`stock_movements` append-only + `stock_balances`/`batches.available_qty` projections) | **VERIFIED** | `internal/domain/inventory/repository.go`; `PostStockMovement` is the only function that touches inventory |
| FEFO/FIFO batch allocation with row-level locking | **VERIFIED** | `inventory.AllocateForSale` uses `SELECT ... FOR UPDATE`; a real concurrency test (two goroutines racing for the same limited batch) confirms exactly the available quantity is sold and stock never goes negative |
| Double-entry accounting journal, DB-enforced balance | **VERIFIED** | `internal/domain/accounting`; the `fn_check_journal_balance` deferred trigger from migration 0009 is exercised for real, and every finalized sale's journal was confirmed debit==credit against the live DB |
| Customer Khata ledger (append-only, derived balance) | **VERIFIED** | `internal/domain/customer`; balance is `SUM(debit)-SUM(credit)`, never a mutable field |
| POS invoice finalization (one atomic transaction: tax calc, batch allocation, stock posting, tenders, ledger, journal, audit) | **VERIFIED** | `internal/domain/pos/service.go`; exercised via real HTTP calls (3 bags @ 1200 + 5% GST = exactly 3780.00, confirmed against the DB) and a full integration test suite |
| Tender-sum validation (must equal grand total) | **VERIFIED** | Rejected a 100/3780 mismatch with `VALIDATION_ERROR` |
| Insufficient-stock rejection (no partial/negative stock) | **VERIFIED** | Rejected a 500-unit request against 97 available; confirmed stock unchanged after rejection |
| Idempotent replay (same device + client_transaction_id) | **VERIFIED** | Replaying an identical finalize request returns the original invoice with `duplicate: true` and does not double-deduct stock |
| Credit-limit enforcement with explicit, audited override | **VERIFIED** (after a real bug fix — see below) | Over-limit credit sales are rejected by default; only succeed with an explicit `override_credit_limit` + reason, gated on the `credit.override` permission, and produce a `CREDIT_OVERRIDE` audit log entry with the reason |
| Invoice numbering (per financial year, row-locked series) | **VERIFIED** | `pos.AllocateInvoiceNumber` uses `SELECT ... FOR UPDATE` on `document_series` |

### Real bug found and fixed this session (Phase 4)
7. **Credit-limit override was silently automatic for any user whose role happened to include the `credit.override` permission** — the first version of the code treated "the caller's JWT carries this permission" as sufficient authorization to bypass a customer's credit limit, with no explicit per-sale decision and no recorded reason. In practice this meant any Owner-role POS session (which reasonably holds every permission) could blow through a customer's credit limit with zero friction and zero audit trail explaining why — directly contradicting PRD 10.1 ("over-limit credit requires configured owner/manager approval and records approver identity/reason"). Caught by manually testing a 40-bag credit sale against a ₹5,000 limit and watching it succeed silently. Fixed by requiring the client to explicitly send `override_credit_limit: true` plus a non-empty `override_reason`; the handler still checks the permission, but the permission alone is no longer sufficient. The override reason is now recorded in a dedicated `CREDIT_OVERRIDE` audit log entry and in the customer ledger description. Covered by three permanent integration test cases (rejected without override, succeeds with reasoned override + audit trail verified, rejected if override requested without a reason).

## Phase 5 — Procurement: GRN with Mandatory Tare Validation

| Area | Status | Evidence |
|---|---|---|
| GRN posting (atomic: batch creation, stock receipt, supplier payable, balanced journal) | **VERIFIED** | `internal/domain/procurement/service.go`; integration-tested against the live DB |
| Tare calculation — both COUNT_BASED (bag count × standard tare/bag) and MEASURED methods | **VERIFIED** | `internal/domain/procurement/tare.go`; `CalculateTare` never assumes a tare value without an explicit method (PRD A7) |
| Tare threshold enforcement, rejected by default, explicit reasoned override | **VERIFIED** | Over-threshold GRN rejected by default; succeeds only with `override_tare` + reason, gated on `grn.override_tare` permission, and produces a `TARE_OVERRIDE` audit entry — same explicit-override pattern as the POS credit-limit fix |
| Negative/implausible net weight rejected | **VERIFIED** | A GRN with tare heavier than gross weight is rejected outright |
| Rejected/damaged/quarantined receipts never enter sellable stock | **VERIFIED** | A fully `REJECTED` GRN line posts (for traceability) but the resulting batch is immediately `QUARANTINED`, and `available_qty` for the product stays zero |
| Supplier payable ledger (liability convention: credit increases payable) | **VERIFIED** | `internal/domain/supplier`; confirmed the outstanding payable after a GRN matches the exact received value |

### Real bug found and fixed this session (Phase 5)
8. **Inventory double-counted every batch receipt**: `inventory.CreateBatch` set `batches.available_qty` directly in its INSERT (to `received_qty`) *and* then called `PostStockMovement`, which — per its own documented contract of being "the only function that should ever change inventory" — also runs `UPDATE batches SET available_qty = available_qty + <received_qty>`. The result: every batch ever created through the normal GRN path silently started with **double** its real received quantity in `available_qty` (though `stock_movements`, the authoritative ledger, was correct throughout — only the projection was wrong). This had not been caught earlier because the POS test fixtures seeded batches with raw SQL `INSERT`s that bypassed `CreateBatch` entirely; it was only caught once GRN posting — which is the real, only intended way batches get created — was exercised end-to-end and the resulting quantity was checked against the DB rather than just checking that the call succeeded. Fixed by inserting `available_qty` as `0` and letting `PostStockMovement`'s own update be the single source of the increment, consistent with the comment already on that function. Covered by an integration test that asserts the exact received quantity, not just success/failure.

## Phase 6 — Sales Returns & Refunds

| Area | Status | Evidence |
|---|---|---|
| Return posting (atomic: quantity validation, restock or quarantine, ledger, journal) | **VERIFIED** | `internal/domain/returns/service.go`; 5 integration tests, all passing against a live DB |
| Return quantity never exceeds remaining eligible (sold minus already returned) | **VERIFIED** | Partial return of 6/10 succeeds, a follow-up attempt to return 5 more (only 4 remain) is rejected, and returning exactly the remaining 4 succeeds |
| Sellable returns restock the exact original batch(es), proportional to the original allocation | **VERIFIED** | Full and partial returns both land back in the same batch the sale was allocated from, preserving batch/expiry traceability |
| Depleted batch reactivation on restock | **VERIFIED** | Selling an entire 5-unit batch marks it `DEPLETED`; returning 2 units reactivates it to `ACTIVE` with the correct quantity |
| Non-sellable (damaged/expired/quarantine) returns never re-enter sellable stock | **VERIFIED** | A `DAMAGED` return leaves the original batch untouched and creates a separate, immediately `QUARANTINED` batch for traceability |
| Refund via cash/UPI journal reversal, or via Khata credit note | **VERIFIED** | Confirmed a credit-note return fully clears the customer's outstanding receivable; confirmed the return journal balances exactly (debit=credit) for a cash refund |
| Proportional tax reversal computed from the original invoice's actual tax lines, not re-derived | IMPLEMENTED | `returns.GetTaxLinesForLine` reads the point-in-time tax amounts the sale actually posted, so a later tax-profile change can never retroactively change a return's tax reversal |

No new bugs were found in this phase — the two-pass "validate and compute everything, then write" structure adopted after the procurement double-counting bug (Phase 5) was reused here from the start, and all 5 tests passed on the first run.

## Not Yet Started

Remaining business domain modules (payment/UPI integration, contra/buy-back,
cash sessions/EOD, reports/dashboards),
idempotency/outbox infrastructure for external side effects (printer/
WhatsApp), Flutter app (offline-first, SQLCipher, POS UI), payment/GST/
WhatsApp provider adapters, hardware adapters (scale/printer/scanner), seed/
config workflows, CI/CD, the rest of the test suites (E2E/offline/chaos/
load), backup/DR tooling, and the remaining documentation set. These will be built in subsequent sessions, in the
priority order set by the master specification (security → financial
integrity → tenant isolation → inventory → payments → compliance → offline
sync → API → backend → Flutter → hardware → UI → reporting → DevOps).

## Production Readiness

**NOT READY.** The database foundation and the auth/identity vertical slice
of the Go backend exist and have been verified end-to-end (real HTTP calls
and automated integration tests against a live PostgreSQL instance). No
business domain logic (POS, inventory, payments, accounting), no client
application, no third-party integrations, and no CI exist yet.
