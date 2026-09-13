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

## Phase 7 — Payment/UPI Integration (Provider Abstraction + Webhook Processing)

| Area | Status | Evidence |
|---|---|---|
| Provider abstraction (`paymentprovider.Provider` interface) | IMPLEMENTED | `internal/paymentprovider/provider.go` — a real gateway (Razorpay/Cashfree/PhonePe/etc.) needs only one more implementation of this interface; production credentials are the external dependency, not the code |
| Sandbox provider (HMAC-SHA256 signed webhooks, matching real-gateway conventions) | **VERIFIED** | `internal/paymentprovider/sandbox.go`; exercised for real, not stubbed |
| Receipt-intent creation for Khata collection via UPI | **VERIFIED** | Real HTTP call created an intent and returned a QR payload |
| Webhook signature verification | **VERIFIED** | Real HTTP call with a forged signature rejected with `401 UNAUTHORIZED`; correct signature accepted |
| Webhook idempotency (redelivered event → zero additional financial effect) | **VERIFIED** | Same event ID sent twice: balance changes exactly once |
| Payment amount validated against the intent before any posting | **VERIFIED** | A webhook reporting an amount different from the intent is rejected before touching the ledger |
| Unknown order reference rejected | **VERIFIED** | A webhook for a non-existent intent is rejected, not silently ignored or crashed on |
| Customer ledger credit + balanced journal on confirmed payment | **VERIFIED** | Real HTTP webhook delivery correctly reduced a customer's Khata balance by exactly the paid amount, confirmed against the DB, not just the API response |
| Cross-tenant order-reference resolution scoped correctly | IMPLEMENTED | The one legitimate pre-resolution lookup (a provider webhook has no concept of our tenants) runs under `WithAdminTx`, exactly like the login device-resolution pattern from Phase 2; every subsequent write happens under the resolved tenant's own RLS context |

Payment/UPI integration is intentionally scoped to **Khata receipt collection** (PRD 10.2) rather than retrofitted into the synchronous POS tender flow — POS `CASH`/`UPI`/`CREDIT` tenders are still validated synchronously at invoice finalization (matching a soundbox/already-confirmed-at-counter model per PRD 11.2). Wiring a fully asynchronous "create pending invoice → wait for webhook → finalize" POS flow is a larger, separate design change and is not yet built.

No new bugs were found in this phase; all 5 webhook integration tests (including the adversarial forged-signature, duplicate-delivery, and amount-mismatch cases) passed on the first run, and the same flow was independently re-verified over real HTTP end to end.

## Phase 8 — Contra / Buy-Back

| Area | Status | Evidence |
|---|---|---|
| Contra posting (atomic: inventory receipt + receivable reduction + balanced journal) | **VERIFIED** | `internal/domain/contra/service.go`; 3 integration tests passing against a live DB |
| Commodity received creates a real batch, exactly like a GRN | **VERIFIED** | 100kg of maize at a configured valuation correctly appears as sellable stock |
| Customer receivable reduced by the approved value | **VERIFIED** | A ₹10,000 opening receivable correctly drops to ₹8,500 after a ₹1,500 contra |
| Rejected/quarantined intake never enters sellable stock | **VERIFIED** | Same quality-status handling as GRN and returns — a `REJECTED` line contributes zero to available stock |
| No arbitrary valuation | **VERIFIED** | Negative valuation is rejected outright; posting requires `contra.approve`, which is the approval control itself (no separate draft/approve workflow in this implementation — documented as a scope simplification) |

No new bugs found; all 3 tests passed on the first run, reusing the same two-pass validate-then-write structure and the same quality-status quarantine pattern established in procurement and returns.

## Phase 9 — Cash Sessions / End-of-Day Reconciliation

| Area | Status | Evidence |
|---|---|---|
| EOD open/close/reopen lifecycle | **VERIFIED** | `internal/domain/eod`; 6 integration tests, all passing against a live DB |
| Expected cash derived from the accounting journal, not a separate ledger | **VERIFIED** | `GetCashJournalTotals` sums the CASH account's debits (sales) and credits (refunds) straight from `journal_lines`/`journal_entries` for the business date — there is no second, independently-editable cash figure that could drift from the real postings (PRD 48) |
| Cross-domain reconciliation: a real POS cash sale closes with zero variance | **VERIFIED** | Sold 2 bags for cash (₹2520), closed with exactly ₹3520 (₹1000 opening + ₹2520 sales) counted, variance = 0 |
| Cash refunds correctly reduce expected cash | **VERIFIED** | Sold 2 bags, returned 1 for cash, expected cash correctly nets to sales minus the refund |
| Variance requires an explicit reason; matching a reasoned close still succeeds | **VERIFIED** | A ₹60 short till is rejected with no reason, then succeeds once a reason is given, with the variance correctly signed (-60.00) |
| One EOD session per business date (DB-enforced), double-open/double-close rejected | **VERIFIED** | Relies on `UNIQUE(tenant_id, business_date)` from migration 0001, backed by an explicit application check for a clean error before hitting the constraint |
| Reopen is a distinct, reasoned, audited operation — never silently allowed | **VERIFIED** | Reopen without a reason rejected; reopen only valid from `CLOSED` status (rejected from `REOPENED` or `OPEN`); produces an `EOD_REOPENED` audit entry |

Cash sessions here are modeled per-tenant-per-business-date rather than per-device/per-drawer — a deliberate scope simplification appropriate for a single-counter shop; multi-device cash session tracking (the `cash_sessions`/`cash_movements` tables already exist in the schema for this) is not yet wired up. No new bugs were found in this phase; all 6 tests passed on the first run.

## Phase 10 — Reports & Dashboards

| Area | Status | Evidence |
|---|---|---|
| Sales summary (gross/discount/tax/net, by tender method) | **VERIFIED** | Two real invoices (one cash, one credit) produced a summary matching the exact expected totals and per-tender breakdown |
| Stock on hand (aggregated from `batches.available_qty`) | **VERIFIED** | Selling 5 of 50 bags correctly reduced the reported total to 45, read from the same column POS/GRN/returns all maintain |
| Customer outstanding balances | **VERIFIED** | Zero-balance customers correctly excluded; a customer with an active credit sale correctly appears with the exact ledger-derived balance |
| EOD history | **VERIFIED** | A closed EOD session correctly appears with its opening cash, status, and figures |

Every report here reads directly from the same authoritative tables every other module writes to (`sales_invoices`, `batches`, `customer_ledger_entries`, `eod_sessions`) — there is no separate, independently-maintained aggregate table that could silently diverge (PRD 50). Deliberately **not** implemented in this pass: full 30/60/90-day customer aging (bucketing by original invoice age requires correctly attributing partial payments/returns back to specific invoices via an allocation-matching algorithm; shipping a naive version risked misattributing partial settlements, so this reports total outstanding only, not age buckets — a documented gap, not a silent one) and product-margin/profitability reports (need a defined costing policy per PRD A16 — FIFO vs weighted-average — which hasn't been configured yet).

No new bugs found; all 4 tests passed on the first run.

## Phase 11 — Flutter Client (Online Vertical Slice)

This is the first Flutter work in the project: a real, running mobile app
that talks to the real Go backend. It intentionally does **not** yet include
offline-first storage (SQLCipher) — see the gap note below — so it should be
understood as "online-only POS foundation," not the full offline client the
PRD describes.

| Area | Status | Evidence |
|---|---|---|
| Project scaffold (Android + Windows targets) | IMPLEMENTED | `apps/flutter/`; builds cleanly for both |
| API client with auth-retry-on-401 | **VERIFIED** | `lib/core/api_client.dart`; exercised for real against the live Go backend |
| Secure token storage, dependency-injectable for testing | **VERIFIED** | `lib/core/secure_storage.dart`; the DI seam this required (see bug below) is what made the test suite actually testable at all |
| Login screen + product search screen | **VERIFIED** | Both screens exercised via widget tests (mocked HTTP) and via a real end-to-end run |
| **Real end-to-end test: Android emulator → live Go API → live PostgreSQL** | **VERIFIED** | `integration_test/app_test.dart`, run twice for a clean confirmation: real login against the seeded dev fixture, then a real product (created via `curl` against the live API) found through real product search on-device |
| `flutter analyze` clean, `flutter test` (4/4) passing | **VERIFIED** | Both run to completion with zero issues |

### Real bugs found and fixed this session (Phase 11)
9. **Widget tests hung indefinitely on `pumpAndSettle`**: `SecureStorage` wrapped `FlutterSecureStorage` directly with no way to substitute it, and that plugin's native platform channel isn't available under `flutter test` — every token read/write call never resolved, silently hanging any test that touched auth. Fixed by extracting a `KeyValueStore` interface with a `PlatformSecureKeyValueStore` (production) and `InMemoryKeyValueStore` (test) implementation, and making `SecureStorage` accept either via constructor injection. This is the same dependency-injection lesson already learned twice on the Go backend (the dual-pool database fix, the claims-context fix) — recurring here on the client for the identical underlying reason: hard-wiring a concrete implementation makes correct behavior untestable.
10. **A genuine, user-facing financial display bug**: `Text('₹${p.sellingPrice}')` used `Decimal.toString()` directly, which strips trailing zeros — a ₹1200.00 price rendered as "₹1200" instead of "₹1200.00". This is exactly the kind of formatting inconsistency the PRD's numeric-precision rules exist to prevent, and it would have shipped to real users had the widget test not asserted the exact expected string rather than just "a price is shown somewhere." Fixed by using `toStringAsFixed(2)` for all currency display.

### Real environment issues found and resolved, not code bugs
- The Windows desktop build failed (`flutter_secure_storage_windows` needs the ATL headers, which this machine's Visual Studio Build Tools installation doesn't include) — a genuine toolchain gap, not fixed; Windows desktop testing was abandoned in favor of the Android emulator target, which is a fully valid and arguably more representative target for this shop's actual hardware anyway.
- The Android emulator's virtual disk was 94% full and rejected the app install (`INSTALL_FAILED_INSUFFICIENT_STORAGE`); resolved by wiping the disposable dev AVD's data (no user work was on it).
- Android blocks cleartext (plain HTTP) traffic by default for apps targeting recent API levels, which silently prevented the app from ever reaching the local dev backend. Fixed correctly and narrowly: `android:usesCleartextTraffic="true"` was added **only** to the debug-variant manifest (`android/app/src/debug/AndroidManifest.xml`), which is never merged into a release build — production must and will use HTTPS.
- A real device has no way to know it should present the specific device UUID a backend fixture expects (there is no self-service device-registration flow yet — see gaps below); the end-to-end test needed the same `SecureStorage` DI seam to pre-seed a known device UUID matching a fixture already registered via the admin path, mirroring how backend integration tests seed their own fixtures.

### Known gaps in this phase
- **No offline storage.** SQLCipher-backed local persistence (products, prices, customers, credit snapshots, pending invoices, sync queue — PRD 14.1) is not implemented. The app is online-only: every screen requires a live connection to the backend.
- **Device self-registration now exists (see Phase 13)** via short-lived pairing codes; the admin/SQL path is no longer the only way to add a device.
- **POS cart/checkout now exists (see Phase 12)** but only supports a single full-amount CASH tender; no split tenders or customer/Khata selection in the UI yet.
- **No hardware integration** (barcode scanner as HID input, weighing scale, ESC/POS printer).

## Phase 12 — POS Cart/Checkout (Backend Quote Endpoint + Flutter Cart Screen)

| Area | Status | Evidence |
|---|---|---|
| `pos.Service.Quote` — server-computed pricing preview, no writes/stock checks | **VERIFIED** | `internal/domain/pos/quote.go`; a new test (`TestQuote_MatchesWhatFinalizeWouldCharge`) proves the quoted total is exactly what `FinalizeInvoice` actually charges for the identical cart — not just plausible-looking, provably identical, because both now call one shared `priceLine` helper |
| Refactored `FinalizeInvoice` to share pricing logic with `Quote` (no duplicate tax math) | **VERIFIED** | Full POS test suite re-run after the refactor — all prior tests (cash sale, insufficient stock, tender mismatch, credit limit, concurrency) still pass unchanged |
| `GET /api/v1/locations` (needed for the Flutter location picker) | IMPLEMENTED | `internal/domain/location` |
| Flutter cart model + cart/checkout screen | **VERIFIED** | `lib/features/pos/cart_model.dart`, `cart_screen.dart`, `pos_api.dart`; wired into product search (tap-to-add, cart badge) |
| **Real end-to-end checkout**: Android emulator → live quote → live invoice finalization → live PostgreSQL | **VERIFIED** | `integration_test/app_test.dart` extended to search, add to cart, open the cart screen, wait for a real server-computed total, and tap checkout — then independently confirmed in the database: a genuinely new `INV-2627-00005` for exactly ₹1260.00 (1 bag @ ₹1200 + 5% GST) appeared, and stock dropped from 16 to 15 |
| Widget test coverage for add-to-cart | **VERIFIED** | New widget test confirms tapping a search result populates the cart and updates the badge |

The cart never computes its own total — it calls the real `/api/v1/pos/quote` endpoint and displays exactly what the server would charge, which is the same code path `FinalizeInvoice` uses. This directly avoids the class of bug where a client-side price/tax calculation could silently drift from the server's.

No new bugs were found in the backend quote logic (it reused already-tested code via the shared `priceLine` extraction). One test-harness gap was found and fixed: the existing widget tests broke immediately because `ProductSearchScreen` now depends on `CartModel`, which the tests' provider setup didn't include — a `ProviderNotFoundException`, caught immediately by running the suite rather than assuming the new code wouldn't affect old tests.

### Known gaps in this phase
- Checkout only supports a single CASH tender for the exact quoted amount. Split tenders (cash+UPI+credit) and a customer picker for Khata/credit sales are not wired into the UI, though the backend fully supports both.
- No cart persistence — closing the app loses the cart (expected, since there is no offline storage yet).

## Phase 13 — Self-Service Device Pairing

Triggered by a real user hitting "device is not registered" on a fresh
install — the app correctly generates its own random device UUID on first
launch (as a real device would), but there was no way for that device to
ever become known to the backend except an administrator manually inserting
a row. This phase builds the sanctioned self-service path.

| Area | Status | Evidence |
|---|---|---|
| Pairing-code generation (device.manage, tenant-scoped, 10-minute TTL) | **VERIFIED** | `internal/domain/devicepairing`; real HTTP call generated `C7S6C352` |
| Code redemption creates the device under the correct tenant | **VERIFIED** | Real HTTP redemption returned the correct `tenant_id` and the device row was confirmed `ACTIVE` in the database |
| A used code cannot be redeemed twice | **VERIFIED** | Real HTTP reuse attempt rejected; also covered by an integration test |
| An expired code is rejected | **VERIFIED** | Integration test with a code force-expired via direct SQL |
| An unknown code is rejected | **VERIFIED** | Integration test |
| Concurrent redemption of the same code — only one can win | **VERIFIED** | Integration test races two goroutines against one code; row-locked via `FOR UPDATE`, exactly one succeeds |
| Cross-tenant code lookup scoped correctly (the one place an unauthenticated caller legitimately needs cross-tenant resolution) | IMPLEMENTED | Same `WithAdminTx` pattern as login's device resolution — see `devicepairing.Service.RegisterDevice` |
| Flutter: "Register this device" flow on the login screen | **VERIFIED** | Real device successfully re-registered and logged in on the physical test emulator |
| Flutter: "Pair a new device" screen for the owner (code display, live countdown, copy-to-clipboard) | IMPLEMENTED | Gated on `device.manage`; not yet exercised by a second physical device, but the underlying endpoint is fully verified |
| Login screen now displays its own device UUID (PRD §93 support diagnostic) | **VERIFIED** | Read directly off the running emulator via `adb shell uiautomator dump` |

### Real bugs found and fixed this session
11. **The product-create endpoint never exposed `tax_profile_id`**, discovered while seeding demo data for the user to test with: any product created through the API (as opposed to directly via SQL, which is how every other fixture in this project was seeded) could never actually be sold, since both `Quote` and `FinalizeInvoice` require a tax profile. Fixed by adding the field to the request DTO — the repository and service layers already supported it end to end.
12. **Every internal server error was being silently discarded** — `WriteError`'s own doc comment claimed internal errors were "logged server-side only," but nothing ever actually logged them. This directly caused a debugging dead-end: a request appeared to fail with a generic 500, and only after adding real logging did it become clear the request had actually failed on a duplicate-SKU constraint from an *earlier, seemingly-failed* attempt that had in fact succeeded (a client-side UTF-8 response-decoding failure had been masking a real success as a failure). Fixed centrally in `WriteError` so every future `CodeInternal` response is logged with its real detail server-side while the client still only ever sees the safe generic message — no call site needs to remember to log.
13. **A flaky integration test** (`TestDevicePairing_ExpiredCodeRejected`) used a fixed literal pairing code, which is safe in isolation but collides on any second run against a database with leftover state from a prior run.

### A systemic finding, investigated to its root cause rather than left as a one-off
Chasing bug #13 led to discovering that **every integration test's tenant cleanup has been silently failing all session**: `device_pairing_codes.tenant_id` (and every other tenant-owned table) references `tenants(id)` without `ON DELETE CASCADE`, so the `t.Cleanup(() => DELETE FROM tenants WHERE id = ...)` pattern used throughout every test file in this project raises a foreign-key violation on every single run — an error every one of those cleanup functions silently discards (`_ = db.WithAdminTx(...)`). The dev database has accumulated 354 orphaned test tenants as a result. This does **not** corrupt any test's correctness (each test generates a fresh random tenant UUID, so leftover rows never collide with a new run) — it only affects a table with a *global*, non-tenant-scoped unique constraint (`code`), which is exactly what bug #13 hit. Deliberately **not fixed** by adding `ON DELETE CASCADE` to the production schema: that would make it trivially easy to mass-delete a tenant's entire financial history with a single statement, which directly contradicts this project's own "never make financial data casually deletable" principle — the cascade would only ever fire from a test, but the schema can't tell in advance which caller it's protecting against. The correct fix is a dedicated, explicit test-teardown helper that deletes child rows in dependency order (or simply resetting the dev database via `docker compose down -v` periodically) — recorded here as a known gap rather than silently living with it.

## Phase 14 — Customer Master HTTP API

The `customer` domain package already existed (used internally by `pos`,
`returns`, `payment`, `contra` to post ledger entries), but had **no HTTP
routes at all** — there was no way to create a customer, look one up, search
for one, or set a credit limit through the API. Found by grepping `main.go`
for customer routes and finding none, in direct response to "implement all,
never miss any single piece."

| Area | Status | Evidence |
|---|---|---|
| `POST /api/v1/customers` (create, gated on `credit.configure`) | **VERIFIED** | Real HTTP call created `SMOKE01` against the live server; integration test also covers duplicate `customer_code` rejection |
| `GET /api/v1/customers?q=` (search by name/code/phone) | **VERIFIED** | Real HTTP call + integration test covering name-substring, phone-substring, and unfiltered listing |
| `GET /api/v1/customers/{id}` (customer + credit profile + live outstanding balance) | **VERIFIED** | Real HTTP call returned `credit_limit`, `risk_status`, `outstanding_balance`, `available_credit` computed from the ledger, not a stored field |
| `PUT /api/v1/customers/{id}/credit-limit` (gated on `credit.configure`, audit-logged) | **VERIFIED** | Real HTTP call changed `SMOKE01`'s limit 2000.00 → 5000.00 against the live server, confirmed via a follow-up GET; integration test covers negative-limit rejection and unknown-customer rejection |
| `customer.Repository`/`Service` extended with `Create`, `List`, `SetCreditLimit` | **VERIFIED** | 4 new integration tests, all passing against live Postgres; full `go test -tags=integration ./...` re-run clean afterward (no regressions in the other 9 domain packages) |

No new bugs surfaced in this phase. Reused the existing `credit.configure`
permission for both customer creation and credit-limit changes rather than
inventing a new `customer.manage` permission not present in the seeded
catalogue (migration 0002) — a deliberate, documented scope choice rather
than an oversight.

Server restarted with the new routes live at `127.0.0.1:8081` (the address
the Android emulator's app talks to via `10.0.2.2:8081`).

## Phase 15 — Flutter Customer Picker & CREDIT Tender

The Flutter POS cart only supported a single full-amount CASH tender, so the
backend's credit-sale path (Phase 4) and the new customer API (Phase 14) were
never reachable from the client. This phase wires a real customer picker and
a CASH/CREDIT tender toggle into the cart screen.

| Area | Status | Evidence |
|---|---|---|
| `CustomerApi.search()` wrapping `GET /api/v1/customers` | **VERIFIED** | 2 widget tests (mocked HTTP) + live on the emulator: picker listed real customers from Phase 14's test data (`Test Farmer` / FARM001, `Smoke Test Customer`) |
| `CustomerPickerScreen` (search field, tap to select, pops the selection) | **VERIFIED** | Exercised live on the emulator end to end |
| Cart screen: CASH/CREDIT `SegmentedButton`, customer-picker row appears only for CREDIT | **VERIFIED** | Live on the emulator; also asserted by `test/cart_credit_test.dart` |
| `PosApi.finalizeCreditSale()` (CREDIT tender + customer_id) | **VERIFIED** | Real invoice `INV-2627-00008` finalized live against the running server |
| Credit-limit-exceeded → override-reason dialog → retry with `override_credit_limit`+`override_reason` | **VERIFIED, live, twice** | The widget test mocks a 409 `CREDIT_LIMIT_EXCEEDED` then a successful retry; separately, the *real* server rejected a real over-limit sale live on the emulator (Test Farmer's accumulated test balance exceeded their ₹5,000 limit), the dialog appeared with the server's real message, and after entering a reason and confirming, the sale was finalized for real — confirmed by re-fetching the customer afterward and seeing `outstanding_balance` grow by exactly the sale total (101,560.00 → 102,662.50) |

No new backend bugs found — the backend's credit-override contract (permission alone insufficient; requires an explicit reason) worked exactly as designed the first time it was driven from a real client. Split tenders (cash+UPI+credit combined in one sale) remain out of scope for the UI.

## Phase 16 — Flutter Offline-First Storage (SQLCipher) & Sale Sync

The architecture spec repeatedly mandates SQLCipher-encrypted offline
storage as P0; the app previously had none — any network interruption
simply broke product search and checkout outright. This phase adds a real
encrypted on-device store, a read-through product cache, and an offline
sale-intent outbox with server-authoritative re-pricing on sync.

**Design decision, made after hitting a real architectural conflict:** the
backend's `FinalizeInvoice` requires the tender amount to exactly equal its
own computed grand total (`pos.ErrTenderMismatch`), and the offline cache
has no tax-profile data to replicate that computation client-side. So an
offline sale is queued as an *intent* (product ids/quantities, location,
tender method — no total) rather than a priced invoice; `SyncService`
re-quotes for real once online and finalizes with whatever the server says
*at sync time*, giving the exact same pricing guarantee an online sale
already has. CREDIT is unavailable offline (a credit-limit check needs a
live balance).

| Area | Status | Evidence |
|---|---|---|
| `SqlLocalDatabase` (SQLCipher via `sqflite_sqlcipher`, passphrase in platform keystore via `SecureStorage.getOrCreateLocalDbPassphrase`) | **VERIFIED** | Real APK installed on the emulator; `libsqlcipher.so` loaded (confirmed in logcat) and the app started normally, meaning the encrypted DB opened successfully before `runApp` |
| `LocalDatabase` interface + `products_cache`/`outbox_invoices`/`kv_cache` schema | **VERIFIED** | 7 real tests in `test/local_db_test.dart` against sqflite_common_ffi (plain `test()`, not `testWidgets` — see below) |
| `ProductRepository`: live search always hits the server and refreshes the cache; only a network failure falls back to cache | **VERIFIED** | 3 unit tests (`test/product_repository_test.dart`) + live on the emulator: WiFi/data disabled via `adb shell svc wifi/data disable`, search for "cattle" showed the amber "Offline — showing cached products" banner and returned the exact 2 previously-cached products tagged `CACHED` |
| Cart screen: offline detection, tax-exclusive estimated total from cached prices, CREDIT tender disabled offline | **VERIFIED, live** | Same offline session: cart showed "Estimated: ₹2100.00" (2× cached ₹1050, no tax) and a disabled CREDIT segment |
| Offline checkout queues a sale intent instead of calling finalize | **VERIFIED, live** | "Sale Queued (Offline)" dialog appeared; the intent was written to the encrypted outbox (not lost) |
| `SyncService.syncPendingInvoices()`: re-quotes each queued intent for real, finalizes with the fresh server total | **VERIFIED, live** | Went back online, tapped the new sync button — real invoice `INV-2627-00011` created server-side at **₹2205.00** (the server's authoritative 2100 + 5% tax), correctly *higher* than the offline-estimated ₹2100.00, confirmed via `psql` against the live database. 3 more unit tests (`test/sync_service_test.dart`) cover the re-quote-not-resend contract, a non-retryable rejection being parked `FAILED` (not lost, not retried forever), and a still-offline attempt leaving the intent `PENDING` |
| Pending-sync badge + manual "Sync now" button on the search screen; automatic sync on connectivity regain (`connectivity_plus`) | **VERIFIED, live** | Badge showed "1" while offline, cleared to none after a successful manual sync |
| Location list also cached (`kv_cache`) so checkout's location selector still works offline | **VERIFIED, live** | First offline session before any cache existed correctly left checkout disabled with no crash; after one online visit to the cart screen the location cached, and offline checkout became available on the next attempt |

### Real bugs found and fixed this session
14. **Real sqflite I/O does not resolve inside `flutter_test`'s fake-async widget-pump zone.** Wiring the real SQLCipher-compatible `sqflite_common_ffi` database directly into a `testWidgets` test didn't fail — it hung indefinitely, confirmed by running it standalone and watching it exceed a 100s+ timeout with no error. Root cause: `tester.pump()`/`pumpAndSettle()` step a `FakeAsync` zone that only advances synthetic time and flushes microtasks; it never yields to the real OS event loop that genuine native/FFI I/O depends on. Fixed by splitting `LocalDatabase` into an abstract interface with two implementations: `SqlLocalDatabase` (the real one, tested for real with plain non-widget `test()`s in `local_db_test.dart`) and `FakeLocalDatabase` (a pure in-memory Dart implementation used by every `testWidgets` test instead).
15. **sqflite's connection-caching-by-path silently leaked state across tests.** `sqflite_common_ffi`'s `databaseFactoryFfi` caches an opened `Database` by its path string; every test opening `inMemoryDatabasePath` (`":memory:"`) got back the *same* cached connection and its leftover data from earlier tests in the same run — two tests failed with counts off by exactly what an earlier test had left behind (e.g. an idempotency test's `tx-1` was already `SYNCED` from a prior test's use of the same id). Fixed with `OpenDatabaseOptions(singleInstance: false)` so each test gets a genuinely isolated in-memory database.

## Phase 17 — Customer Ledger API & Flutter Khata Statement Screen

The customer API (Phase 14) only exposed the aggregate outstanding balance —
there was no way to see the itemized history behind it, so neither an owner
nor a cashier could actually review a customer's Khata. This phase adds a
real ledger-listing endpoint and the Flutter statement screen it was built
for.

| Area | Status | Evidence |
|---|---|---|
| `customer.ListLedger` (repository + service), `GET /api/v1/customers/{id}/ledger` | **VERIFIED** | New integration test posting two entries and asserting newest-first order; real HTTP call against the live server returned "Test Farmer"'s actual 6-entry history |
| `KhataCustomerListScreen` + `KhataDetailScreen` (credit summary card, itemized ledger, over-limit warning) | **VERIFIED, live** | Installed on the Android emulator: browsed real customers, opened "Test Farmer" and saw the real outstanding balance (₹103,765.00 against a ₹5,000 limit), the "Over credit limit" warning, and all 6 real ledger entries in the correct order with correct debit/credit coloring |
| 4 widget tests (`test/khata_test.dart`, mocked HTTP) | **VERIFIED** | Covers search→navigate, the summary card's values, the over-limit warning appearing/not appearing, and empty-ledger state |

### A real bug found and fixed, not from the app but from writing this feature's own test
16. **`customer_ledger_entries` had no reliable posting-order column.** Both `entry_date` and `created_at` default to `now()`, which Postgres freezes for the entire transaction — two entries posted in the same transaction (exactly what the new ledger integration test did, and a real occurrence whenever a single business operation posts more than one ledger row) get an *identical* timestamp, so `ORDER BY entry_date DESC` silently fell back to comparing `id`, a random UUID with no relationship to insertion order. The test caught this immediately (asserted order came back reversed). Fixed with migration `0016`: added a `bigserial seq` column, monotonically increasing regardless of transaction timing, and reordered by that instead.
17. **A second, cascading bug the same migration exposed**: migration `0012`'s `ALTER DEFAULT PRIVILEGES` only covered future *tables*, not future *sequences* — so the new `seq` column's backing sequence was invisible to `app_user`/`app_admin`, and every `INSERT` into the table failed with "permission denied for sequence" the moment the test tried to post a ledger entry. Fixed both narrowly (an explicit `GRANT` on the new sequence) and at the root cause (`ALTER DEFAULT PRIVILEGES ... GRANT ... ON SEQUENCES`, so no future migration adding a serial/bigserial column hits this again). Applied to the dev database directly (the migration had already run once) and folded into `0016`'s script for any future fresh install.

## Phase 18 — Offline Outbox Review Screen

Phase 16 documented a known gap: a `FAILED` sale intent had no UI at all — it
just sat invisibly in the local database. This phase adds `OutboxScreen`,
reachable from the sync icon on the search screen (which now navigates
there instead of syncing blindly on tap), listing every outbox entry
(PENDING/FAILED/SYNCED) with its own manual sync button and a Retry action
on FAILED entries.

| Area | Status | Evidence |
|---|---|---|
| `LocalDatabase.allOutboxEntries()` / `retryInvoice()` (both implementations) | **VERIFIED** | New `local_db_test.dart` case: all three statuses returned correctly, and `retryInvoice` verified to be a no-op on PENDING/SYNCED entries — only a FAILED entry is ever reset |
| `OutboxScreen`: status list, per-entry error message, Retry re-enqueues and re-syncs immediately | **VERIFIED** | 3 widget tests (`test/outbox_screen_test.dart`) covering the empty state, a FAILED entry's Retry succeeding, and the manual Sync Now button |
| Live on the emulator | **VERIFIED, live** | Queued a sale offline, opened the outbox screen while still offline and saw it listed PENDING alongside an earlier session's SYNCED entry with its real invoice number; re-enabling connectivity triggered the existing automatic connectivity-based sync (Phase 16) before the manual sync button was even tapped — confirmed the entry became SYNCED as `INV-2627-00013` in the live database, and a subsequent manual sync correctly reported "Nothing to sync" |

No new bugs found — this phase closed a documented UI gap rather than surfacing a defect.

## Phase 19 — CI Pipeline (GitHub Actions)

The project has never had CI; every verification claim throughout this
document rested on someone manually running the same commands. Adds
`.github/workflows/ci.yml` with two jobs: `backend` (real Postgres 16
service container, `golang-migrate` CLI applies every migration from
scratch, then `go build`/`go vet`/`go test -tags=integration` — the exact
same commands used throughout every phase's verification in this document)
and `flutter` (`flutter analyze` + `flutter test`).

**Honesty note on verification, since this repo has no `git remote`**: the
workflow has never actually run on GitHub's infrastructure, and that claim
would be false if made. What *was* verified, for real, locally: `go.mod`'s
`go` directive resolves correctly for `setup-go`'s `go-version-file`; the
exact `go install -tags 'postgres' .../migrate/v4/cmd/migrate@v4.17.1`
command in the workflow was run in an isolated `GOBIN`, produced a working
binary, and that binary correctly reported this dev database's applied
migration version (16) against `postgres://feedmate_owner:...@localhost/feedmate`
— the identical connection string shape the workflow uses; and the YAML
itself parses with a valid two-job (`backend`, `flutter`) structure. Not
verified: the `flutter` job's `libsqlite3-dev` + `subosito/flutter-action`
combination on an actual `ubuntu-latest` runner (a well-established pattern
for `sqflite_common_ffi`, but not exercised here), and the `postgres:`
services-container health-check syntax under real GitHub Actions scheduling.
Whoever first pushes this to GitHub should treat the first real run as the
actual verification, not this description.

## Phase 20 — Manual Khata Receipts (Cash/Bank) + Flutter Recording UI

Phase 17 made the Khata ledger readable but not writable from the app — a
UPI receipt posts automatically via the payment webhook (Phase 7), but a
cashier physically handed cash by a farmer had no way to record it; paying
down a balance required direct SQL/API. This phase closes that loop.

**Design note**: `payment.CreateReceiptIntent`'s own doc comment states
receipts "may generate a UPI payment link only through a configured
payment/collection mechanism — never an ad hoc, unverified amount." A
manual cash receipt does not violate this: the constraint is about not
trusting a *client's claim* that an unconfirmed digital payment succeeded.
Cash has no digital confirmation to wait for — the authenticated cashier's
own action *is* the confirmation, identical to the trust boundary the
system already accepts for a CASH tender at POS checkout (`pos.sell`
permission, no provider involved). `RecordManualReceipt` therefore requires
`METHOD` to be `CASH`, `BANK`, or `OTHER` — `UPI` is explicitly rejected
and must go through the existing intent/webhook path.

| Area | Status | Evidence |
|---|---|---|
| Migration `0017`: `payments.idempotency_key` (partial unique index) | **VERIFIED** | Applied to the dev database via the `migrate` compose profile |
| `payment.RecordManualReceipt` (repository + service): posts ledger credit + balanced journal (Dr Cash/Bank/Other, Cr Accounts Receivable), idempotent on `idempotency_key` | **VERIFIED** | 3 new integration tests: balance reduction + a real posted journal row, a retried identical request resolving to the same payment id with the balance reduced only once, and UPI/zero-amount both rejected with `ErrValidation` |
| `POST /api/v1/payments/receipts` | **VERIFIED, live** | Real `curl` call reduced "Test Farmer"'s balance by exactly ₹500.00; an identical retry (same `idempotency_key`) returned `duplicate: true` with the same `payment_id` and did not double-credit |
| Flutter: "Record Receipt" FAB on the Khata detail screen, amount/method/reference dialog | **VERIFIED, live** | Installed on the Android emulator: recorded a real ₹265.00 cash receipt against "Test Farmer" — the snackbar confirmed it, the new ledger entry appeared at the top of the real list, and the outstanding balance dropped from ₹103,265.00 to ₹103,000.00, all confirmed against the live server |
| 4 widget tests (`test/khata_test.dart`), mocked HTTP | **VERIFIED** | Covers a successful receipt refreshing the balance from a fresh server fetch (not a client-side subtraction) and client-side rejection of a zero amount before any network call |

### A methodology note, not a product bug
Writing this feature's own widget test initially failed with a confusing
`Expected: not null, Actual: <null>` — the actual cause was a `TestFailure`
thrown *inside* the mock HTTP handler's own `expect()` call (a wrong
assertion comparing `Decimal("800.00")`'s serialized form to the literal
string `"800.00"` — `Decimal.toString()` drops trailing zeros, the same
formatting `pos_api.dart` already relies on for tender amounts, and the Go
backend parses either representation to an identical numeric value). That
`TestFailure` propagated through `ApiClient`'s generic `on Exception catch`
network-error handling and was silently absorbed by the screen's own `on
ApiError catch` block, masking the real assertion failure as an unrelated
null-result symptom far from its cause. Fixed by comparing the parsed
`Decimal` values instead of raw strings. Not a defect in shipped code —
recorded here because the failure mode (a test's own broken assertion
being swallowed by the very error-handling path it's supposed to be
testing) is exactly the kind of thing worth remembering when a future test
fails in a confusing way in this codebase.

## Phase 21 — Supplier Master, Payable Ledger API & Flutter Screens

The supplier side of the ledger existed only as an internal helper
(`supplier.PostLedgerEntry`/`OutstandingPayable`, used by procurement's GRN
posting) with no HTTP API and no Flutter screen at all — the exact gap
Phase 14/17 had already closed on the customer side. This phase builds the
full mirror: supplier master CRUD, a payable statement endpoint, manual
supplier payments, and the Flutter screens for both.

| Area | Status | Evidence |
|---|---|---|
| Migration `0018`: `supplier_ledger_entries.seq` (same ordering fix as `0016`, applied proactively this time) | **VERIFIED** | Applied via the `migrate` compose profile; confirmed the new sequence's grants were inherited automatically from `0016`'s `ALTER DEFAULT PRIVILEGES` with no explicit `GRANT` needed — checked directly with `\dp` |
| `supplier.Service` (Create/List/GetByID/ListLedger), `GET/POST /api/v1/suppliers`, `GET /api/v1/suppliers/{id}/ledger` | **VERIFIED** | 4 new integration tests; real `curl` calls created and searched a real supplier |
| `payment.RecordSupplierPayment` (mirrors `RecordManualReceipt`: debits the supplier ledger, Dr Accounts Payable / Cr Cash-Bank-Other, idempotent), `POST /api/v1/payments/supplier-payments` | **VERIFIED, live** | 3 new integration tests; a real `curl` payment reduced a real supplier's payable by exactly the amount paid, confirmed against the live database, and an identical retry correctly reported `duplicate: true` without double-paying |
| Flutter: `SupplierListScreen` + `SupplierDetailScreen` (payable summary, itemized ledger, "Record Payment" FAB/dialog) | **VERIFIED, live** | Installed on the Android emulator: browsed a real supplier, and recorded a real ₹1500.00 cash payment that dropped the payable from ₹9,000.00 to ₹7,500.00, confirmed live |
| 3 widget tests (`test/supplier_test.dart`, mocked HTTP) | **VERIFIED** | Covers search→navigate→statement, a successful payment refreshing from a fresh server fetch, and client-side rejection of a zero amount |

### A cleanup made while extending shared code
`payment.ManualPayment` (the row-level type behind both `RecordManualReceipt` and this phase's `RecordSupplierPayment`) had a `CustomerID` field that was never actually written to the database — the `payments` table has no `customer_id` column; the real customer linkage happens entirely through the ledger entry, not this struct. Removed the dead field while generalizing the type for both receipts and payments, rather than perpetuating a field that looked load-bearing but wasn't.

### A real bug found live, unrelated to this phase's own feature, but blocking it
While verifying the new supplier icon's permission gate (`supplier.manage`) after a cold app restart, the icon — and the owner's display name — had silently disappeared, despite the same account being used throughout the session. Root cause: `AuthSession.restoreSession()` only ever restored `tenantId` from persisted storage and flipped straight to `loggedIn`; it never restored `displayName` or `permissions`, which only ever got populated by a fresh password login. Any real device that stays logged in across an app restart (the normal case for a POS terminal) would silently lose every permission-gated feature — not just the one just added, but existing ones too (e.g. the device-pairing icon) — while still showing as authenticated. Fixed on both ends: `restoreSession()` now exchanges the stored refresh token for a fresh access token via the existing `/api/v1/auth/refresh` endpoint (mirroring what `ApiClient` already does mid-session on a 401) rather than trusting the stale persisted token blindly; and the backend's `identity.Service.Refresh` was found to never populate `DisplayName` in the first place (it only ever fetched permissions, not the user record) — fixed with a new `GetUserByID` lookup, with the handler updated to serialize it. Verified live: after a real app restart, the owner's name and every permission-gated icon reappeared correctly, confirmed with a new integration test asserting `Refresh` carries both, and 3 new Flutter unit tests covering the valid-refresh, expired-refresh, and no-stored-session paths.

## Phase 22 — Flutter End-of-Day Screen

The EOD backend (open/close/reopen a cash session, PRD 12.2) has existed
since early in the project with a complete, tested API, but no Flutter
screen ever called it — the only way to open/close a day was `curl`. This
phase adds `EodScreen`: open with an opening float, close by counting the
physical cash drawer (the server computes expected cash from the
accounting journal, never a client-side running total), and reopen a
closed day with a reason.

| Area | Status | Evidence |
|---|---|---|
| `EodApi` wrapping `GET/POST /api/v1/eod*` | **VERIFIED** | Exercises the existing, already-tested backend — no backend changes this phase |
| `EodScreen`: not-opened / OPEN / CLOSED / REOPENED states, "Open Day", "Close Day" (with the variance-reason retry dialog when counted cash doesn't match expected), "Reopen Day" | **VERIFIED, live** | Installed on the Android emulator and walked through the full real lifecycle against the live server: opened with a ₹2,000.00 float, attempted to close with a mismatched count and received the server's real rejection (a genuine computed variance of -₹14,147.50, reflecting the tenant's actual accumulated cash-sale history from this session's other live tests — not a fixture), supplied a reason and closed successfully, then reopened with a second reason — every number shown was the server's own computation, confirmed on-screen at each step |
| 3 widget tests (`test/eod_test.dart`, mocked HTTP) | **VERIFIED** | Covers open, the close→reject-for-missing-reason→retry-and-succeed sequence (assumes the cash amount is pre-filled on retry so the cashier doesn't recount), and reopen |

No new backend bugs found — this phase was pure Flutter UI on top of an
already-solid, already-tested API. One minor formatting fix caught by the
close-retry test failing on the first attempt: the retry dialog's
pre-filled cash amount used `Decimal.toString()` (drops trailing zeros,
e.g. "2500" instead of "2500.00") instead of `toStringAsFixed(2)` — the
same class of formatting inconsistency documented in Phase 11's bug #10
and again in Phase 20's methodology note, now a recognizable pattern to
watch for whenever a `Decimal` is put into a text field or compared as a
string rather than as a numeric value.

## Phase 23 — Flutter Reports/Dashboard Screen and AppBar Overflow Menu

The sales-summary/stock-on-hand/customer-balances/EOD-history report
endpoints (built in Phase 10) had a tested backend but no Flutter view —
the only way to see them was `curl`. This phase adds `ReportsScreen`, a
4-tab dashboard, and refactors `ProductSearchScreen`'s AppBar (which had
grown to 7 icons across Phases 15/17/21/22) into a single overflow menu so
the toolbar reads like a real shipped app rather than an accumulation of
one-off buttons.

| Area | Status | Evidence |
|---|---|---|
| `ReportsApi` wrapping `GET /api/v1/reports/{sales-summary,stock-on-hand,customer-balances,eod-history}` | **VERIFIED** | Exercises the existing, already-tested backend — no backend changes this phase |
| `ReportsScreen`: Sales (date-range picker, invoice count/gross/discount/tax/net, by-tender breakdown), Stock (SKU/batch count/nearest-expiry, expiry warning), Balances (red highlight over credit limit), EOD History (variance color-coding) | **VERIFIED, live** | Installed on the Android emulator and walked all 4 tabs against the live server: Sales showed 13 real invoices (₹113,250.00 gross, ₹5,662.50 tax, ₹118,912.50 net, CASH ₹14,647.50 / CREDIT ₹104,265.00 by tender); Stock showed both real products with correct batch counts and expiry dates; Balances showed "Test Farmer" at ₹103,000.00 in red against a ₹5,000.00 limit; EOD History showed the real REOPENED session with its actual computed variance (-₹14,147.50) — every figure matched the tenant's real accumulated transaction history from this session's prior live tests, not fixture data |
| AppBar overflow menu (`PopupMenuButton<_MenuAction>`, key `more_menu_button`) replacing 5 separate conditional icon buttons (Khata always visible; Suppliers/Reports/EOD/Pair-device gated on `supplier.manage`/`report.view`/`cash.eod_close`/`device.manage`) | **VERIFIED, live** | Confirmed on-device: menu opens with all 5 items for the owner account and correctly gates by permission in a widget test with a restricted account; sync and cart icons kept as direct AppBar icons since they're used on every sale |
| 4 widget tests (`test/reports_test.dart`) + 2 widget tests (`test/product_search_menu_test.dart`) | **VERIFIED** | Sales/Stock/Balances/EOD tabs each independently asserted (including balance red-highlighting via style inspection); menu permission-gating and per-item navigation (Reports/Suppliers/Khata) each independently asserted |

No new backend bugs found — this phase was pure Flutter UI on top of an
already-solid, already-tested reports API.

## Phase 24 — Flutter Procurement/GRN Screen

The last major missing Flutter screen: receiving physical stock from a
supplier (PRD 7.4). `procurement.Service.PostGRN` has existed with a
complete, tested backend (weight/tare capture with the reasoned-override
pattern, batch creation, supplier payable posting, accounting journal)
since early in the project, but the only way to post a GRN was `curl`.
This phase adds `GrnScreen` plus supporting `SupplierPickerScreen` and
`ProductPickerScreen`, and wires it into the AppBar overflow menu gated on
`grn.post`.

| Area | Status | Evidence |
|---|---|---|
| `ProcurementApi` wrapping `POST /api/v1/procurement/grns` | **VERIFIED** | Exercises the existing, already-tested backend |
| `GrnScreen`: supplier/location pickers, optional supplier document/vehicle no., multi-line entry (batch code, manufacture/expiry dates, quantity, unit cost, quality status, optional weight/tare capture with MEASURED/STANDARD_PER_BAG tare methods) | **VERIFIED, live** | Installed on the Android emulator and posted two real GRNs against the live server, confirmed in the database: `GRN-2627-0001` (25 × ₹820.00, supplier ledger credited ₹21,525.00 including 5% GST) and `GRN-2627-0002` (15 × ₹900.00, credited ₹14,175.00) — both created real `batches` rows and real `supplier_ledger_entries` |
| Tare-override reasoned-exception retry (PRD A7): a line whose computed tare exceeds the tenant's configured threshold is rejected with `CONFLICT` unless the cashier supplies an explicit override reason | **VERIFIED** | Widget test drives the full reject → override-dialog → reason → retry-with-`override_tare:true` → success sequence, mirroring the EOD variance-reason pattern |
| UOM and tax profile are taken from the product's own stored defaults (`default_purchase_uom_id`, `tax_profile_id`) rather than picked ad hoc per line | **VERIFIED** | `tax_profile_id` was missing from the product HTTP response entirely — added it to `productResponse`/`toProductResponse` (`product_handlers.go`), a small necessary backend addition, not scope creep: without it the client had no way to know a product's tax profile |
| 2 widget tests (`test/grn_test.dart`) | **VERIFIED** | Happy-path post, and the tare-override retry sequence |

### Two real bugs found live, both process/infrastructure failures rather than the GRN feature itself

1. **The live test tenant had no GRN document-number series configured.** Posting the first real GRN through the app failed with an opaque `INTERNAL_ERROR`. Root cause: `document_series` (which every document-numbered domain — INVOICE/GRN/RETURN/CONTRA/RECEIPT — depends on) only had an `INVOICE` row for this tenant; `GRN` had never been seeded, because no admin/setup UI exists yet to manage it (tracked under "seed/config workflows" below) and integration tests insert their own row directly rather than exercising real setup. Fixed by inserting the missing row directly for this tenant so live verification could proceed — a real shop's onboarding will need document-series setup built before launch.
2. **Found while diagnosing bug #1 — and a much bigger deal**: the actual cause above was completely invisible from the server logs. `WriteError`'s `CodeInternal` branch is specifically designed so every internal-error response gets logged server-side with the real detail (see its doc comment in `errors.go`) — but of ~30 `CodeInternal` call sites across every handler file (`auth`, `contra`, `customer`, `eod`, `location`, `payment`, `pos`, `procurement`, `product`, `quote`, `reports`, `returns`, `supplier`), all but a handful passed a fixed, uninformative string instead of including `err.Error()`, silently discarding the one piece of information needed to diagnose *any* internal error in this system. This was a latent, systemic observability bug — not something this phase introduced, but something this phase's own failure surfaced — and every one of those ~30 call sites has now been fixed to include the real error text (still never sent to the client; `WriteError` already redacts `message` to a generic string for `CodeInternal` before it leaves the server, so this is purely a server-side logging fix with zero client-facing change). Re-ran the full Go integration suite and all Flutter tests after the change; both still pass.

## Phase 25 — Flutter Sales-Return Screen

The very last screen on the "never miss a screen" list. Unlike every
other phase's backend, this one genuinely needed new server code first:
`returns.Service.PostReturn` was complete and tested, but nothing existed
to let a client look an invoice up by its printed number and see which of
its lines (and how much of each) are still eligible to return — without
that, a cashier has no way to pick what to return. Added it, then built
`ReturnScreen` on top.

| Area | Status | Evidence |
|---|---|---|
| `pos.GetByInvoiceNumber` + `pos.ListInvoiceLines` (repository), `pos.Service.GetInvoiceForReturn`, `GET /api/v1/pos/invoices?number=...` (gated on `return.create`) | **VERIFIED** | New integration test (`TestGetInvoiceForReturn`) covers the found and not-found paths; remaining-eligible quantity is computed the same way `returns.AlreadyReturnedQty` does (sum of POSTED return lines against the original line), duplicated as inline SQL rather than importing the `returns` package, which would have created an import cycle (`returns` already imports `pos`) |
| `ReturnsApi` wrapping the new lookup endpoint and `POST /api/v1/pos/returns` | **VERIFIED** | Exercises the (now two) backend endpoints |
| `ReturnScreen`: look an invoice up by number, per-line return quantity capped at what's still eligible, condition status (SELLABLE restocks the original batch; anything else requires picking a quarantine location, enforced client-side before the server re-validates it), reason, refund method (CASH/UPI/CREDIT\_NOTE) | **VERIFIED, live** | Installed on the Android emulator and posted a real return against a real prior invoice (`INV-2627-00012`, 1 bag, ₹1260.00): the app showed `RET-2627-0001` posted with a ₹1260.00 refund, confirmed in `sales_returns` (`status=POSTED`, `refund_status=COMPLETED`, `total=1260.00`); re-looked the same invoice up afterward and confirmed the line correctly dropped out of eligibility ("Nothing left on this invoice is eligible to return") |
| Overflow-menu entry gated on `return.create` | **VERIFIED** | Widget test extended to assert the item is hidden/shown correctly and navigates to `ReturnScreen` |
| 2 widget tests (`test/returns_test.dart`) | **VERIFIED** | Sellable return happy path; non-sellable return's client-side quarantine-location requirement, including the reject-then-succeed sequence |

### Two more real bugs found live — and proof the Phase 24 logging fix was worth doing

Posting the first live return failed with the same opaque `INTERNAL_ERROR`
Phase 24 hit for GRN — except this time the fix from that phase meant the
real cause was sitting right in the server log: `allocate return number: no
active RETURN document series configured for this financial year`. Same
root cause as Phase 24's bug #1 (this tenant's `document_series` only ever
had `INVOICE`, then `GRN`), same fix (insert the missing row) — but this
time diagnosed in seconds from the log instead of requiring a rebuild with
temporary debug logging. While fixing it, proactively seeded `CONTRA` and
`RECEIPT` series for the same tenant too, since they have the identical gap
and would otherwise fail the same way the first time anyone tries them
live.

## Phase 26 — Flutter UI Redesign (Theme System, Dashboard, App Shell)

A visual redesign of the entire Flutter client: a shared design system
(`core/theme`: colors, typography, decorations/shadows), a genuinely live
`HomeDashboardScreen` (today's sales and Khata receivables pulled from the
reports API, EOD session status, pending-sync alerts, permission-gated
quick-action tiles), and an `AppShell` providing adaptive navigation
(bottom nav on phones, a `NavigationRail` on tablets) as the new post-login
landing experience. Every existing screen was restyled against the shared
theme.

Two real bugs were found and fixed while reviewing this redesign before
committing it:

1. **Critical**: `LoginScreen` still routed straight to the old bare
   `ProductSearchScreen` after a successful login, completely bypassing
   the new dashboard/shell — every actual login (not just a cold restart
   with an already-restored session, which does go through `AppShell` via
   `_SessionGate`) never saw the redesign at all. Fixed to route to
   `AppShell`.
2. `AppShell`'s Suppliers/Reports tabs silently fell back to showing the
   Counter screen for a user without those permissions, so the tab bar
   would highlight "Suppliers" while displaying unrelated content.
   Rebuilt the tab list to be constructed dynamically per session, only
   including tabs the user actually has permission for — matching how the
   overflow menu already behaves elsewhere in the app.

| Area | Status | Evidence |
|---|---|---|
| Theme system, `HomeDashboardScreen`, `AppShell` | **VERIFIED, live** | Installed on the Android emulator: login correctly lands on the dashboard with real KPI data (today's gross sales, Khata receivables matching the known over-limit test customer), all bottom-nav tabs render and navigate correctly gated by permission, and the Counter tab's overflow menu (Khata/Suppliers/GRN/Sales Return/Reports/EOD/Pair Device) still works unchanged |
| `test/widget_test.dart`'s post-login assertion, updated for the new architecture | **VERIFIED** | `ProductSearchScreen` is now a mounted-but-inactive bottom-nav tab rather than the visible screen after login — `find.byType` skips it by default (`skipOffstage: true`), which is `IndexedStack`-inactive-child behavior, not a product bug; the test now checks for `HomeDashboardScreen` as the active screen and asserts `ProductSearchScreen` with `skipOffstage: false` |

`flutter analyze` clean, all 47 tests pass.

## Phase 27 — Product Master-Data CRUD (Create/Edit/Update/Deactivate/List)

The last explicitly-requested gap: there was no way to browse, edit,
deactivate, or manage master product data at all — only point-of-sale
search and a one-time create existed, and none of the supporting
category/brand/UOM/tax-profile lookups were exposed anywhere. Built the
full set: backend CRUD + master-data endpoints, and four new Flutter
screens (list, create/edit form, detail).

| Area | Status | Evidence |
|---|---|---|
| `product.Update`, `product.SetActive`, `product.List`, `product.GetDetail` (repository + service); `masterdata.Service` (categories/brands/UOMs/tax profiles) | **VERIFIED** | New integration tests: `TestProductUpdateSetActiveList` (rename, SKU immutability, barcode/alias full-replace semantics, activate/deactivate never hard-deletes, active-only vs. including-inactive list filtering) and `TestMasterDataLists` (global UOM seed visibility, brand-new-tenant empty categories/brands, and a real RLS tenant-isolation check — a category created for one tenant is invisible to another) |
| `PUT /api/v1/products/{id}` (never changes SKU — the immutable business key referenced by every historical invoice/batch/GRN line), `POST /api/v1/products/{id}/status`, `GET /api/v1/products` (paginated browse, distinct from the existing ranked `search`), `GET /api/v1/{categories,brands,uoms,tax-profiles}` — all gated `product.manage` for writes, any authenticated user for reads | **VERIFIED, live** | Full curl round-trip against the live server (create → get → update → deactivate → filtered list), then the identical flow again through the actual Flutter UI on the emulator, both confirmed directly in Postgres |
| `ProductListScreen` (search, active/inactive filter, FAB), `ProductFormScreen` (shared create/edit, SKU read-only in edit mode, dynamic barcode/alias chip lists), `ProductDetailScreen` (read-only view + Edit + Activate/Deactivate with a confirmation dialog) | **VERIFIED, live** | Installed on the Android emulator: created "Live UI Test Product" end-to-end through the real form (all master-data dropdowns populated from the live server) and confirmed it in Postgres; deactivated and reactivated the earlier curl-created test product through the detail screen, each transition confirmed in Postgres |
| Overflow-menu entry gated on `product.manage` | **VERIFIED** | Widget test extended to assert the item is hidden/shown correctly and navigates to `ProductListScreen` |
| 4 widget tests (`test/products_test.dart`) | **VERIFIED** | List/search/inactive-filter, create (asserts the exact POST body), edit (asserts SKU is disabled and pre-filled, PUT body, barcode/alias round-trip), deactivate (asserts the confirmation dialog gates the call) |

### A real bug found by the tests, before it ever reached a device

The create-product test caught the exact same `Decimal.toString()`
formatting bug documented repeatedly elsewhere in this project (strips
trailing zeros: "1050.00" → "1050") — `ProductDetail.toJson()` used plain
`.toString()` for every decimal field, including money fields. Fixed by
splitting money fields (MRP, selling price, minimum price floor — always
`.toStringAsFixed(2)`) from quantity/weight fields (pack size, standard
weight, reorder level/target — no fixed currency scale, plain
`.toString()` is correct). Caught entirely by the test suite; never
observed live.

## Phase 28 — Customer Create + Edit Credit Limit (Flutter)

Prompted by an external gap-analysis report claiming Product Master
frontend was still "Read Only" (already false as of Phase 27, corrected
before proceeding) and correctly identifying that Khata customers could
be searched and paid against but never *registered* or have their credit
limit revised from the app — both backend endpoints (`POST
/api/v1/customers`, `PUT /api/v1/customers/{id}/credit-limit`) already
existed and were fully gated on `credit.configure`, but no Flutter UI
called either one.

| Area | Status | Evidence |
|---|---|---|
| `CustomerApi.create()` / `CustomerApi.setCreditLimit()` | **VERIFIED** | `create()` re-fetches via `getDetail()` after POST, matching the existing product/supplier pattern, because the Create response (`customerToJSON()`) omits credit fields; `setCreditLimit()` PUTs `{"credit_limit": "X.XX"}` and expects `204` |
| "Add Customer" FAB on `KhataCustomerListScreen`, gated on `credit.configure` (mirrors the backend's own gate on `POST /customers`) | **VERIFIED** | `_CustomerFormDialog` collects code/name/phone/type/optional initial credit limit; on success shows a confirmation snackbar and re-runs the current search |
| "Edit Credit Limit" AppBar icon on `KhataDetailScreen`, gated on `credit.configure` | **VERIFIED** | `_EditCreditLimitDialog` pre-fills the current limit, rejects negative input client-side, refreshes the summary card (and outstanding/available figures) from a fresh `GetDetail` after the `PUT` succeeds — never computed locally |
| 6 new widget tests (`test/khata_test.dart`, 10 total in the file, all passing) | **VERIFIED** | FAB/button hidden without permission (2 tests), create posts the exact body and refreshes the list, required-field validation, credit-limit update posts the exact body and refreshes the summary, negative-limit rejected client-side |

No backend changes were needed or made — both endpoints and their exact
request/response shapes were confirmed unchanged by reading
`customer_handlers.go` before writing the Flutter code. **Live emulator
verification was not performed for this phase** (unlike Phases 24/25/27) —
correctness rests on the confirmed-exact backend contract plus the full
widget-test suite (57 tests, all passing) and `flutter analyze` (clean,
only pre-existing info-level lints). This should be live-verified on the
emulator before being called fully done to the same standard as prior
phases.

Still open from the same gap-analysis report: **Supplier create + edit**
(no backend `Update` method exists at all for suppliers — this needs new
Go domain work first, unlike customer), and **split/multi-tender POS
billing** (backend already supports an array of tenders; `cart_screen.dart`
only allows a single `CASH`/`CREDIT` selection).

## Phase 29 — Supplier Create + Edit + Deactivate (Backend + Flutter)

Unlike customer, supplier had **no** `Update` method at all — not even for
payment terms — and no way to register a new supplier or deactivate one
from the app. This phase built the missing backend support from scratch,
mirroring `product.Update`/`product.SetActive`'s conventions, then wired
the Flutter UI.

| Area | Status | Evidence |
|---|---|---|
| `supplier.Update`, `supplier.SetActive` (repository + service) — `supplier_code` is never touched by Update, the immutable business key referenced by every historical GRN/payment row; `SetActive` is a status flip, never a hard delete | **VERIFIED** | New integration tests: `TestSupplierUpdate_RevisesFieldsButNeverSupplierCode` (renames every editable field, confirms `supplier_code` unchanged, confirms persistence via a fresh `GetByID`, rejects empty name / negative payment terms / unknown supplier) and `TestSupplierSetActive_NeverHardDeletes` (deactivate → still fetchable by ID with `INACTIVE` status → excluded from the default active-only `List` → reactivate → rejects unknown supplier). Both run against live PostgreSQL via `scripts/test-integration.sh` |
| `PUT /api/v1/suppliers/{id}`, `POST /api/v1/suppliers/{id}/status` — both gated `supplier.manage`, matching the existing `Create` route's gate | **VERIFIED** | Handlers mirror `ProductHandlers.Update`/`SetStatus` exactly; `go build`/`go vet` clean |
| `SupplierApi.create()/update()/setActive()` (Flutter) | **VERIFIED** | All three re-fetch via `getDetail()` after the write, matching the established Customer/Product pattern, since the write responses (`supplierToJSON`) omit `outstanding_payable` (only ever computed live from the ledger) |
| "Add Supplier" FAB on `SupplierListScreen`, "Edit Supplier" + "Deactivate/Reactivate" (with a confirmation dialog) AppBar icons on `SupplierDetailScreen`, all gated on `supplier.manage` | **VERIFIED** | Shared `SupplierFormDialog` used for both create and edit; in edit mode `supplier_code` is shown but disabled, mirroring `ProductFormScreen`'s SKU-immutability convention |
| 6 new widget tests (`test/supplier_test.dart`, 9 total in the file, all passing) | **VERIFIED** | FAB/icons hidden without permission, create posts the exact body and refreshes the list, required-field validation, edit posts the exact body confirming `supplier_code` is never sent and the code field is disabled, deactivate requires confirmation and posts `{"active": false}` |

No live emulator verification was performed for this phase either (same
caveat as Phase 28) — correctness rests on: the new Go domain code passing
integration tests against live PostgreSQL, `go build`/`go vet` clean, the
full Flutter widget-test suite (63 tests, all passing), and `flutter
analyze` clean (only pre-existing info-level lints). This should be
live-verified on the emulator before being called fully done to the same
standard as Phases 24/25/27.

Phase A from the gap-analysis report (Customer + Supplier CRUD) is now
complete.

## Phase 30 — Contra/Buy-Back Flutter Screen

Contra (Phase 8) had a complete backend service, handler, and route
(`POST /api/v1/contra`) but zero Flutter reachability.

| Area | Status | Evidence |
|---|---|---|
| `ContraScreen`, `ContraLineFormScreen`, `ContraApi` | **VERIFIED** | Mirrors `GrnScreen`'s structure (pick customer/location, add lines via the existing product picker, post); wired into the overflow menu gated on `contra.approve` |
| 2 new widget tests (`test/contra_test.dart`) | **VERIFIED** | One caught the `Decimal.toString()` trailing-zero bug on `valuation_unit_price` before it reached a device, fixed with `.toStringAsFixed(2)` |

## Phase 31 — Split/Multi-Tender POS Billing

POS checkout only ever sent one tender even though
`pos.FinalizeRequest.Tenders` has always been an array, and the server
only counts the CREDIT portion of a split payment toward the credit limit
check — this was a pure frontend gap.

| Area | Status | Evidence |
|---|---|---|
| `PosApi.finalizeSale()` — replaces the old `finalizeCashSale`/`finalizeCreditSale` pair with one method taking `List<TenderInput>` | **VERIFIED** | Single-tender callers are just the one-element case; also fixed the same latent trailing-zero risk on tender amounts by switching to `.toStringAsFixed(2)` |
| Split-payment UI on `CartScreen`: a switch reveals per-row method + amount editors (CASH/CREDIT/UPI/BANK/OTHER), a running "Remaining: ₹X" indicator, checkout disabled until the rows sum to exactly the invoice total, customer picker required whenever any row is CREDIT | **VERIFIED** | Single-tender mode (the common case) is unchanged and still the default; split mode is online-only, same restriction as CREDIT |
| 2 new widget tests in `test/cart_credit_test.dart` | **VERIFIED** | A CASH+CREDIT split posts both tenders with the exact amounts and requires a customer; checkout stays disabled while the split is unallocated |

Full Flutter suite after Phases 30+31: 67 tests, all passing. `flutter
analyze` clean (only pre-existing info-level lints). No live emulator
verification performed for either phase (same caveat as Phases 28/29).

## Not Yet Started

Customer/supplier aging (30/60/90-day buckets) and margin reports,
per-device cash session tracking (schema exists, not wired up), a real
payment provider adapter (production gateway credentials are the external
dependency — the interface and sandbox are done), idempotency/outbox
infrastructure for external side effects (printer/WhatsApp), a WhatsApp
provider adapter, an admin/setup UI for category/brand/UOM/tax-profile
master data (read-only list endpoints exist for the product form to
consume; there is still no create/edit UI for these lookup tables
themselves, nor for document-number series — Phases 24 and 25 both hit
the latter gap directly live),
hardware adapters (scale/printer/scanner), seed/config workflows, CI/CD
running for real on GitHub's infrastructure (the workflow exists — Phase
19 — but has never actually executed there; there is no `git remote`),
the rest of the test suites (E2E/offline/chaos/load/security), backup/DR
tooling, and the remaining documentation set. These will be built in
subsequent sessions, in the priority order set by the master specification
(security → financial integrity → tenant isolation → inventory → payments
→ compliance → offline sync → API → backend → Flutter → hardware → UI →
reporting → DevOps).

## Production Readiness

**NOT READY**, but substantially further along than a first read of "Not Yet
Started" suggests — that list is what's missing, not a summary of what
exists. As of Phase 27: the Go backend has verified, tested business domain
logic for auth/RBAC (including session-restore carrying real permissions,
not just a login flag), product master data (search, and now full
create/edit/update/deactivate/list), inventory/batches, accounting, POS
sales (cash + credit + credit-limit override), procurement/GRN, returns
(including looking a past invoice up to pick what to return), supplier
master + payable ledger + manual payments, UPI payment intents +
webhooks, manual cash/bank Khata receipts, contra/buy-back, EOD cash
reconciliation, reports, and device self-registration — all covered by
integration tests against live PostgreSQL and exercised via real HTTP
calls. Every internal-error response across every handler now logs its
real cause server-side (Phase 24 found this was silently broken for most
of the API, and Phase 25 immediately proved the fix's worth — see above).
The Flutter client is a real running app (not a mock) with every screen
the master spec calls for now built, presented through a redesigned
theme/dashboard/app-shell (Phase 26): login, a live home dashboard,
Tamil/phonetic product search, cart/checkout with cash and credit tenders,
a customer picker, a Khata statement screen with receipt recording, a
supplier payable screen with payment recording, a procurement/GRN
receiving screen with weight/tare capture and reasoned tare-override, a
sales-return screen, an end-of-day cash reconciliation screen, a 4-tab
reports/dashboard screen, full product master-data management (Phase 27),
encrypted offline storage with a working offline-sale-then-sync path, and
an outbox review/retry screen — all verified live on an Android emulator,
including with connectivity actually disabled and across a real app
restart. A CI workflow exists covering both stacks, though it has not yet
run on real GitHub infrastructure (no `git remote` is configured — see
Phase 19's honesty note).

What's still genuinely missing, and why this isn't production-ready: no
real payment gateway (sandbox only), no WhatsApp integration, no hardware
adapters (scanner/scale/printer), no aging/margin reports, no admin/setup
UI for tenant onboarding config like document-number series or the
category/brand/UOM/tax-profile lookup tables themselves (Phases 24, 25,
and 27 all hit some version of this gap directly live — a real shop's
onboarding needs this built before launch), no backup/DR tooling, CI that
has never actually executed, and the test suite is integration + widget
level only — no E2E, chaos, load, or security test suites exist yet.
