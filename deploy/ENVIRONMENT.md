# Environment & secrets reference

Every env var / secret the deployed stack needs, in one place. The
application code never hardcodes any of these — see
`services/api/internal/config/config.go` for the Go side and
`apps/flutter/lib/main.dart`'s `_defaultApiBaseUrl()` for Flutter. Standing
up a fresh environment (a new GCP project, a new Cloudflare account, a new
Aiven project, or swapping any one of them out) means filling in this list
again — no code changes.

## Current architecture

```
Flutter web/APK/Windows  --(API_BASE_URL, baked in at build time)-->
Cloudflare Pages (web) + R2 (APK/Windows downloads)
Cloudflare Worker (deploy/cloudflare/worker) --[X-Edge-Secret]--> Cloud Run (Go API) --> Aiven Postgres
```

The Worker exists because Cloud Run domain-mappings aren't supported in
every region (notably `asia-south1`, chosen for latency to India) — see
the comment at the top of `deploy/cloudflare/worker/worker.js`.

## Cloud Run (Go API) — env vars

| Var | Required | Notes |
|---|---|---|
| `DATABASE_URL` | yes (directly, or via `APP_SECRETS_FILE`) | `app_user` role, RLS-scoped connections |
| `DATABASE_ADMIN_URL` | yes (directly, or via `APP_SECRETS_FILE`) | `app_admin` role, used only for cross-tenant admin ops |
| `JWT_SIGNING_KEY` | yes in production | |
| `SANDBOX_WEBHOOK_SECRET` | yes in production (unless a real `PAYMENT_PROVIDER` is configured) | |
| `APP_ENV` | no (default `development`) | set to `production` on Cloud Run |
| `PORT` | auto-set by Cloud Run | do not set manually — `resolveHTTPAddr()` prefers it automatically |
| `GCP_PROJECT_ID` | optional | enables the GCP card in the Cloud Usage dashboard; uses the service's own Cloud Run identity (Application Default Credentials) — no key file needed, just the two IAM roles `deploy/gcp/deploy-api.sh` grants |
| `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | optional | enables the Cloudflare card; token needs Account Analytics + Billing read scopes |
| `AIVEN_API_TOKEN`, `AIVEN_PROJECT`, `AIVEN_SERVICE` | optional | enables the Aiven disk-limit reading; disk *usage* is always live via `pg_database_size()` regardless |
| `CLOUD_USAGE_POLL_INTERVAL` | no (default `1h`) | |
| `EDGE_SHARED_SECRET` | strongly recommended in production (directly, or via `APP_SECRETS_FILE`) | must match the Worker's copy; blocks direct traffic to the bare `*.run.app` URL — see `middleware.RequireEdgeSecret`. Leave unset only for local dev. |
| `CRON_SECRET` | required on Cloud Run (directly, or via `APP_SECRETS_FILE`) | gates `/api/v1/internal/cron/*` (billing cycle, cloud-usage poll, DB backup trigger) — see "Scheduled jobs" below |
| `ENABLE_IN_PROCESS_SCHEDULER` | no (default `true`) | set to `false` on Cloud Run (done by `deploy-api.sh`) — see "Scheduled jobs" below |
| `FIREBASE_PROJECT_ID` | optional | enables push notifications (`internal/domain/pushnotify`) — in practice the same value as `GCP_PROJECT_ID`, since Firebase is added to the existing GCP project (see `deploy/gcp/setup-firebase.sh`, one-time). Uses the same Cloud Run ambient identity as the GCP Cloud Usage card — no separate credential, just the `roles/firebasecloudmessaging.admin` IAM grant `deploy-api.sh` adds. |

Every "optional" var above degrades gracefully when unset — that provider's
dashboard card (or, for the edge secret, the edge-secret check itself) is
simply skipped, never a startup failure.

### One secret, not six: `app-secrets`

Every production secret this service needs — `DATABASE_URL`,
`DATABASE_ADMIN_URL`, `JWT_SIGNING_KEY`, `SANDBOX_WEBHOOK_SECRET`,
`EDGE_SHARED_SECRET`, `CRON_SECRET`, `CLOUDFLARE_API_TOKEN`,
`AIVEN_API_TOKEN` — lives in **one** Secret Manager secret, `app-secrets`,
as a single JSON object:
```json
{"database_url":"...","database_admin_url":"...","jwt_signing_key":"...",
 "sandbox_webhook_secret":"...","edge_secret":"...","cron_secret":"...",
 "cloudflare_api_token":"...","aiven_api_token":"..."}
```
Mounted as a **file** (a Cloud Run secret volume, not a plain env var) at
`APP_SECRETS_FILE`, which `config.Load()` parses — see
`loadJSONSecretFile` in `config.go`. The individual env vars
(`DATABASE_URL` etc.) still work directly and take priority when set,
which is what local dev and the self-hosted/VPS `docker-compose.prod.yml`
path use — no JSON file involved there.

This replaced an earlier design with six separate secrets (one per
value, two of them already consolidated pairs) after a billing audit
found it had drifted to **10 active versions** against Secret Manager's
free tier of 6/billing account — old versions had accumulated from
updates that created a new version without disabling the previous one.
One secret with one active version leaves maximum headroom under that
limit permanently, not just "currently at the line."

### One-time secret setup (GCP Secret Manager)
```bash
gcloud secrets create app-secrets --project=$GCP_PROJECT_ID --replication-policy=automatic
# --data-file MUST point at a file with NO byte-order mark. In
# PowerShell, use [System.Text.Encoding]::ASCII — NEVER the plain
# [System.Text.Encoding]::UTF8 constant, which silently prepends a BOM
# that Go's encoding/json rejects outright ("invalid character '?'
# looking for beginning of value").
#
# This caused a real production outage once (under the old multi-secret
# design): a file-mounted JSON secret had a BOM from the day it was
# created, but it went undetected because a stale plain env var (left
# over from `--remove-env-vars` silently NOT removing a *secret-backed*
# env var — see the gotcha below) was masking it as a fallback the whole
# time. The moment that stale fallback was properly removed, every fresh
# container instance failed to start. `loadJSONSecretFile` logs a
# slog.Error on any read/parse failure specifically so this class of bug
# is never silent again — if you see "config: failed to parse JSON
# secret file" in the logs, suspect a BOM first.
gcloud secrets versions add app-secrets --project=$GCP_PROJECT_ID --data-file=path/to/app-secrets.json
gcloud secrets add-iam-policy-binding app-secrets --project=$GCP_PROJECT_ID \
  --member="serviceAccount:$(gcloud projects describe $GCP_PROJECT_ID --format='value(projectNumber)')-compute@developer.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"
```

**Gotcha: removing a *secret-backed* env var needs `--remove-secrets`, not
`--remove-env-vars`.** `--remove-env-vars` only removes plain env vars —
against a secret-backed one it is a silent no-op (no error, the entry just
stays). Use `gcloud run services update --remove-secrets=NAME1,NAME2`
instead. If you also need to touch the file-mounted secret in the same
call, re-pass `--update-secrets` with its *existing* mount path in the
very same command — repeating `--update-secrets` for an already-mounted
path across separate commands creates a **second, differently-named
volume** for the same mount path instead of updating the first one
(Cloud Run auto-suffixes the volume name), and two volumes racing for the
same container path breaks startup. Prefer one atomic
`--remove-secrets=... --update-secrets=...` call over several incremental
ones, and sanity-check with
`gcloud run revisions describe <rev> --format=json` (look at `spec.volumes`
for duplicates) if a deploy ever fails mysteriously after touching secrets.
Mount the secret as a file with
`--update-secrets="/secrets/app/app-secrets.json=app-secrets:latest"` plus
`--update-env-vars="APP_SECRETS_FILE=/secrets/app/app-secrets.json"`
pointing at that same path.

**When rotating any one value, you're replacing the whole JSON object** —
fetch the current version, edit the one field that changed, and
`gcloud secrets versions add` the full object back. Adding a new version
this way is normal and expected (that's what keeps the secret current);
what caused the earlier 10-version drift was never disabling/destroying
the *previous* version after doing so. After rotating, check
`gcloud secrets versions list app-secrets` and destroy anything older
than the new `latest` that's no longer needed:
`gcloud secrets versions destroy <old-version-number> --secret=app-secrets --project=$GCP_PROJECT_ID`.

**Use `printf '%s'`, never `echo` or a PowerShell pipe, when writing a
secret value** — both can silently append a trailing newline, which Go's
`net/http` then rejects as an invalid header value if that secret is later
sent as a header (this broke the Cloudflare/Aiven tokens once already this
session).

## Cloudflare Worker (`deploy/cloudflare/worker/`)

| Setting | Where | Notes |
|---|---|---|
| `ORIGIN_HOST` | `wrangler.toml` `[vars]` | the Cloud Run origin hostname — edit this one line to migrate regions/projects |
| custom domain route | `wrangler.toml` `routes` | must stay *above* `[vars]` in the file — TOML section ordering, not a wrangler quirk |
| `EDGE_SHARED_SECRET` | Worker secret (`wrangler secret put`) | must match the API's own `EDGE_SHARED_SECRET` |

## Cloudflare Pages (web app)

| Var | Where | Notes |
|---|---|---|
| `API_BASE_URL` | `--dart-define` at build time (`deploy/cloudflare/deploy-web.sh`) | baked into the compiled JS — changing it means rebuilding, not just redeploying |
| `CF_PAGES_PROJECT` | script arg | the Pages project name |

## Cloudflare R2 (downloads)

| Var | Where | Notes |
|---|---|---|
| `R2_BUCKET` | script arg (`deploy/cloudflare/upload-downloads.sh`) | |

## Flutter APK/Windows builds

Same `API_BASE_URL` dart-define as the web build — see
`apps/flutter/lib/main.dart:39-44`. With no override, it falls back to
`http://10.0.2.2:8081` (Android emulator loopback) or `http://127.0.0.1:8081`
— **never** a production domain, so a build is safe by default if someone
forgets the flag (it just won't reach anything in production, rather than
silently hitting the wrong account).

## Database (Aiven, or any other Postgres host)

Nothing in the app assumes Aiven specifically. `DATABASE_URL` /
`DATABASE_ADMIN_URL` are the only way the app learns how to reach Postgres,
both required with no fallback host. Migrations (`db/migrations/`) use only
standard Postgres extensions (`pgcrypto`, `pg_trgm`, `btree_gist`) available
on any provider or self-hosted instance. Moving to a different DB host is a
pure config change — run the migrations against the new host, update the
two URLs, redeploy.

## Scheduled jobs: billing cycle, cloud-usage poll & overdue sweep

Three background jobs run periodically: the subscription billing cycle
(marks overdue tenants `PAST_DUE`/`SUSPENDED`), the cloud-usage poll
(populates the platform admin's Cloud Usage dashboard), and the overdue
sweep (pushes a `payment_overdue` notification — see
`internal/domain/notify` — to tenants with customers who still owe and
haven't paid in a while). How they're driven differs by deployment target
— `ENABLE_IN_PROCESS_SCHEDULER` picks which:

- **Self-hosted / VPS** (`ENABLE_IN_PROCESS_SCHEDULER=true`, the default):
  an in-process `time.Ticker` goroutine, since the process runs
  continuously there and a ticker is genuinely reliable.
- **Cloud Run** (`ENABLE_IN_PROCESS_SCHEDULER=false`, set by
  `deploy/gcp/deploy-api.sh`): **do not rely on the ticker** — confirmed by
  checking the actual logs, Cloud Run's scale-to-zero (the container can be
  torn down entirely while idle) and its default CPU throttling (CPU is
  frozen between requests, even on a warm instance) mean an in-process
  ticker only ever fires at container boot, never on its real schedule.
  Instead, two Google Cloud Scheduler jobs (provisioned by the same deploy
  script when `EDGE_SHARED_SECRET` and `CRON_SECRET` are set in the shell)
  call `POST /api/v1/internal/cron/daily-tasks` (every 24h — combines the
  billing cycle and overdue sweep into one call, see
  `CronHandlers.RunDailyTasks`'s doc comment) and
  `POST /api/v1/internal/cron/cloud-usage-poll` (hourly), each carrying
  both `X-Edge-Secret` and `X-Cron-Secret`. This keeps the same "pay only
  for real work" cost profile scale-to-zero already gives the rest of the
  app — each scheduled hit is just one more cheap request — while
  guaranteeing the jobs actually run on schedule. See
  `services/api/internal/httpapi/cron_handlers.go`'s doc comment.

  **Only 2 jobs, deliberately** — Cloud Scheduler's Always Free tier is
  3 jobs per billing account (not per project). The DB backup trigger
  (below) is a 3rd *logical* job but runs on a Cloudflare Cron Trigger
  instead, specifically to leave this account at 2/3 GCP Scheduler jobs
  with a full spare slot, not 3/3 — don't add a 4th Scheduler job here
  without first checking whether it can go on Cloudflare's side instead.

One-time setup on a fresh project (after `CRON_SECRET` exists in Secret
Manager per the pattern above):
```bash
gcloud services enable cloudscheduler.googleapis.com --project=$GCP_PROJECT_ID
EDGE_SHARED_SECRET=$(gcloud secrets versions access latest --secret=edge-shared-secret --project=$GCP_PROJECT_ID) \
CRON_SECRET=$(gcloud secrets versions access latest --secret=cron-secret --project=$GCP_PROJECT_ID) \
  deploy/gcp/deploy-api.sh
```

## Automated database backups

Split deliberately across two providers, each doing the part it's
actually good at:

```
Cloudflare Worker Cron Trigger (deploy/cloudflare/db-backup/, daily, free)
  --POST /internal/cron/trigger-db-backup, X-Cron-Secret-->
Cloud Run API (internal/domain/dbbackup.Trigger, ambient credentials)
  --Cloud Run Admin API jobs.run-->
Cloud Run Job feedmate-db-backup (deploy/backup/ — pg_dump, free tier)
  --PUT, Authorization: Bearer UPLOAD_SECRET-->
Cloudflare Worker (same one, fetch() handler, R2 binding)
  --writes-->
R2 bucket bpks-db-backups (private, 90-day lifecycle rule, free tier)
```

**Why not GCP Cloud Scheduler for this?** Scheduler's Always Free tier is
3 jobs/billing account; the app already needs 2 (see "Scheduled jobs"
above). A 3rd for backups would leave zero headroom and risk tipping into
billing on the very next thing that needs scheduling. Cloudflare Cron
Triggers have no comparable per-account job cap, so backup scheduling
lives there instead.

**Why not a GCS bucket for storage?** No reason beyond consolidation —
this stack's actual storage/CDN layer is already Cloudflare (Pages, R2 for
downloads), so backups use R2 too rather than splitting storage across two
providers for no benefit. `bpks-db-backups` is a **separate, private**
bucket from the public downloads one — never give it a public custom
domain or enable its r2.dev URL.

**Why does `pg_dump` still run on Cloud Run at all, then?** Cloudflare
Workers run in a V8 isolate, not a container — they cannot execute
`pg_dump` or any other arbitrary binary. A Cloud Run Job is the smallest
piece of real compute this stack has, and it's already confirmed to run
entirely within Cloud Run's free tier (scale-to-zero; a sub-minute daily
job is negligible CPU-time).

Two non-obvious things this needed, both documented in
`deploy/backup/backup.sh`'s comments:
- **`pg_dump` requires a client version >= the server's.** The image uses
  `postgres:18-trixie` as its base specifically so the bundled `pg_dump`
  always matches whatever Postgres major version the server runs (e.g.
  Aiven) — bump the tag if that version ever changes, rather than fighting
  Debian stable's own (older) `postgresql-client` package.
- **`app_admin` has no `BYPASSRLS`** (by design — see migration
  `0012_rls_policies.up.sql`); it instead requires an explicit
  `app.admin_mode=on` session flag, set via `PGOPTIONS`. `pg_dump` also
  defaults to requesting `row_security=off` (an unfiltered dump), which
  only a superuser/`BYPASSRLS` role may do — `--enable-row-security` makes
  it dump through RLS normally instead, which (combined with
  `admin_mode=on` making every table's policy permissive to `app_admin`)
  still yields a complete, every-tenant dump.

Trigger one manually (any of these three, equivalent):
- `curl -X POST https://api.bpkscattlefeeds.com/api/v1/internal/cron/trigger-db-backup -H "X-Cron-Secret: <cron_secret>"`
- `gcloud run jobs execute feedmate-db-backup --region=asia-south1 --project=<project>`
- From `deploy/cloudflare/db-backup/`: `wrangler dev --test-scheduled`, then `curl -X POST "http://127.0.0.1:<port>/cdn-cgi/handler/scheduled?cron=0+2+*+*+*"`

List backups: `wrangler r2 object get "bpks-db-backups/<filename>" --file=<local-path> --remote` (no bulk list command in wrangler; check the Cloudflare dashboard's R2 browser for the full list).
Restore: `pg_restore --clean --if-exists --dbname="<admin_url>" <dump-file>`.

### One-time setup on a fresh environment
1. `deploy/gcp/deploy-db-backup.sh` (GCP side — builds the image, creates the Cloud Run Job, grants it read access to `app-secrets` and `roles/run.invoker` to both the backup-scheduler SA and the API's own runtime SA).
2. `gcloud artifacts repositories set-cleanup-policies cloud-run-source-deploy --location=<region> --policy=deploy/gcp/artifact-cleanup-policy.json` — keeps Artifact Registry's own storage within its free tier automatically (see below).
3. From `deploy/cloudflare/db-backup/`: `wrangler deploy`, then `wrangler secret put CRON_SECRET` (same value as the API's) and `wrangler secret put UPLOAD_SECRET` (a fresh random value — must also be set as the Cloud Run Job's `UPLOAD_SECRET` env var).

### Keeping Artifact Registry itself inside the free tier
Every `gcloud builds submit` (for both the API and the backup image) adds
a new untagged image layer set; left unpruned these accumulate and will
eventually exceed Artifact Registry's 0.5 GB free allowance.
`deploy/gcp/artifact-cleanup-policy.json` (applied via
`gcloud artifacts repositories set-cleanup-policies`, see above) handles
this automatically and permanently: keeps the 5 most recent image
versions regardless of tag state, and deletes any other untagged image
older than 1 day. Set once; never needs manual pruning again.

## Alternative: self-hosted / VPS deployment

`deploy/compose/docker-compose.prod.yml` is a complete, generic Docker
Compose stack (Postgres + API + a `migrate` one-shot service) with no
cloud-provider lock-in — it's the supported fallback if you'd rather
self-host on any VPS instead of Cloud Run. The same `services/api/Dockerfile`
image runs unmodified either way (it only reads `PORT`/`HTTP_ADDR`, not
anything Cloud-Run-specific). You'd additionally need your own reverse
proxy (e.g. Caddy) for TLS/routing, since this compose file doesn't publish
ports to the host by design — see the comments at the top of the file.

## `internal/domain/cloudusage` — a deliberate exception

This package (the platform-admin Cloud Usage dashboard) is intentionally
coupled to GCP + Cloudflare + Aiven specifically — it polls each one's own
API for free-tier usage. It is **not** a generic "any cloud provider"
abstraction, and that's a deliberate tradeoff, not an oversight: building a
plugin system for three fixed vendors wouldn't be worth the complexity. If
you drop one of these three providers, that provider's card on the
dashboard simply stops populating (every poller already no-ops cleanly when
its credentials are unset) — nothing else breaks.
