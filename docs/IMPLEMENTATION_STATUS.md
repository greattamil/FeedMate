# Andipatti Animal Feed System — Implementation Status

Last updated: 2026-09-12

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

## Not Yet Started

Everything else required by the 19 specifications: Go backend (API,
business logic, idempotency, outbox), Flutter app (offline-first,
SQLCipher, POS UI), payment/GST/WhatsApp provider adapters, hardware
adapters (scale/printer/scanner), reporting, seed/config workflows, CI/CD,
full test suites (unit/integration/E2E/offline/chaos), backup/DR tooling,
and the remaining documentation set. These will be built in subsequent
sessions, in the priority order set by the master specification (security →
financial integrity → tenant isolation → inventory → payments → compliance
→ offline sync → API → backend → Flutter → hardware → UI → reporting →
DevOps).

## Production Readiness

**NOT READY.** Only the database foundation exists and has been verified.
No API, no business logic, no client application, no integrations, and no
CI exist yet.
