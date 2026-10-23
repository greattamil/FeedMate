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
| `DATABASE_URL` | yes (directly, or via `DB_CREDENTIALS_FILE`) | `app_user` role, RLS-scoped connections |
| `DATABASE_ADMIN_URL` | yes (directly, or via `DB_CREDENTIALS_FILE`) | `app_admin` role, used only for cross-tenant admin ops |
| `JWT_SIGNING_KEY` | yes in production | |
| `SANDBOX_WEBHOOK_SECRET` | yes in production (unless a real `PAYMENT_PROVIDER` is configured) | |
| `APP_ENV` | no (default `development`) | set to `production` on Cloud Run |
| `PORT` | auto-set by Cloud Run | do not set manually — `resolveHTTPAddr()` prefers it automatically |
| `GCP_PROJECT_ID` | optional | enables the GCP card in the Cloud Usage dashboard; uses the service's own Cloud Run identity (Application Default Credentials) — no key file needed, just the two IAM roles `deploy/gcp/deploy-api.sh` grants |
| `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | optional | enables the Cloudflare card; token needs Account Analytics + Billing read scopes |
| `AIVEN_API_TOKEN`, `AIVEN_PROJECT`, `AIVEN_SERVICE` | optional | enables the Aiven disk-limit reading; disk *usage* is always live via `pg_database_size()` regardless |
| `CLOUD_USAGE_POLL_INTERVAL` | no (default `1h`) | |
| `EDGE_SHARED_SECRET` | strongly recommended in production (directly, or via `INTERNAL_SECRETS_FILE`) | must match the Worker's copy; blocks direct traffic to the bare `*.run.app` URL — see `middleware.RequireEdgeSecret`. Leave unset only for local dev. |
| `CRON_SECRET` | required on Cloud Run (directly, or via `INTERNAL_SECRETS_FILE`) | gates `/api/v1/internal/cron/*` (billing cycle, cloud-usage poll) — see "Scheduled jobs" below |
| `ENABLE_IN_PROCESS_SCHEDULER` | no (default `true`) | set to `false` on Cloud Run (done by `deploy-api.sh`) — see "Scheduled jobs" below |
| `FIREBASE_PROJECT_ID` | optional | enables push notifications (`internal/domain/pushnotify`) — in practice the same value as `GCP_PROJECT_ID`, since Firebase is added to the existing GCP project (see `deploy/gcp/setup-firebase.sh`, one-time). Uses the same Cloud Run ambient identity as the GCP Cloud Usage card — no separate credential, just the `roles/firebasecloudmessaging.admin` IAM grant `deploy-api.sh` adds. |

Every "optional" var above degrades gracefully when unset — that provider's
dashboard card (or, for the edge secret, the edge-secret check itself) is
simply skipped, never a startup failure.

### Why two secrets are JSON files, not four separate ones

Secret Manager's free tier is **6 active secret versions/month** (pooled
per billing account) — beyond that, each extra version costs a small
amount. To stay at exactly 6 rather than quietly drifting over it,
`DATABASE_URL`+`DATABASE_ADMIN_URL` share one secret (`db-credentials`,
a JSON object `{"url":"...","admin_url":"..."}`) and
`EDGE_SHARED_SECRET`+`CRON_SECRET` share another (`internal-secrets`,
`{"edge_secret":"...","cron_secret":"..."}`). Both are mounted as **files**
(Cloud Run secret volumes, not plain env vars) at `DB_CREDENTIALS_FILE` /
`INTERNAL_SECRETS_FILE`, which `config.Load()` parses — see
`loadJSONSecretFile` in `config.go`. The individual env vars
(`DATABASE_URL` etc.) still work directly and take priority when set,
which is what local dev and the self-hosted/VPS `docker-compose.prod.yml`
path use — no JSON file involved there. Current total: 6 secrets
(`db-credentials`, `internal-secrets`, `jwt-signing-key`,
`sandbox-webhook-secret`, `cloudflare-api-token`, `aiven-api-token`) — at
the free-tier line, not over it.

### One-time secret setup (GCP Secret Manager)
```bash
# plain string secrets: JWT_SIGNING_KEY, SANDBOX_WEBHOOK_SECRET,
# CLOUDFLARE_API_TOKEN, AIVEN_API_TOKEN
gcloud secrets create <name> --project=$GCP_PROJECT_ID --replication-policy=automatic
printf '%s' "<value>" | gcloud secrets versions add <name> --project=$GCP_PROJECT_ID --data-file=-
gcloud secrets add-iam-policy-binding <name> --project=$GCP_PROJECT_ID \
  --member="serviceAccount:$(gcloud projects describe $GCP_PROJECT_ID --format='value(projectNumber)')-compute@developer.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# the two JSON secrets (db-credentials, internal-secrets): same create +
# add-iam-policy-binding, but --data-file MUST point at a file with NO
# byte-order mark. In PowerShell, use [System.Text.Encoding]::ASCII —
# NEVER the plain [System.Text.Encoding]::UTF8 constant, which silently
# prepends a BOM that Go's encoding/json rejects outright
# ("invalid character '?' looking for beginning of value").
#
# This caused a real production outage once: the file-mounted JSON
# secrets had a BOM from the day they were created, but it went
# undetected because a stale plain env var (DATABASE_URL etc., left
# over from `--remove-env-vars` silently NOT removing a *secret-backed*
# env var — see the gotcha below) was masking it as a fallback the whole
# time. The moment that stale fallback was properly removed, every fresh
# container instance failed to start. `loadJSONSecretFile` now logs a
# slog.Error on any read/parse failure specifically so this class of bug
# is never silent again — if you see "config: failed to parse JSON
# secret file" in the logs, suspect a BOM first.
```

**Gotcha: removing a *secret-backed* env var needs `--remove-secrets`, not
`--remove-env-vars`.** `--remove-env-vars` only removes plain env vars —
against a secret-backed one it is a silent no-op (no error, the entry just
stays). Use `gcloud run services update --remove-secrets=NAME1,NAME2`
instead. If you also need to touch the file-mounted secrets in the same
call, re-pass `--update-secrets` with their *existing* mount paths in the
very same command — repeating `--update-secrets` for an already-mounted
path across separate commands creates a **second, differently-named
volume** for the same mount path instead of updating the first one
(Cloud Run auto-suffixes the volume name), and two volumes racing for the
same container path breaks startup. Prefer one atomic
`--remove-secrets=... --update-secrets=...` call over several incremental
ones, and sanity-check with
`gcloud run revisions describe <rev> --format=json` (look at `spec.volumes`
for duplicates) if a deploy ever fails mysteriously after touching secrets.
Mount a plain secret as an env var with
`gcloud run services update <service> --update-secrets="ENV_NAME=<secret-name>:latest"`,
or a JSON one as a file with
`--update-secrets="/secrets/<dir>/<file>.json=<secret-name>:latest"`
(each secret needs its **own** directory under `/secrets/` — Cloud Run
rejects two different secrets mounted in the same directory) plus
`--update-env-vars="DB_CREDENTIALS_FILE=/secrets/db/db-credentials.json"`
(or `INTERNAL_SECRETS_FILE=...`) pointing at that path.

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

## Scheduled jobs: billing cycle & cloud-usage poll

Two background jobs run periodically: the subscription billing cycle
(marks overdue tenants `PAST_DUE`/`SUSPENDED`) and the cloud-usage poll
(populates the platform admin's Cloud Usage dashboard). How they're driven
differs by deployment target — `ENABLE_IN_PROCESS_SCHEDULER` picks which:

- **Self-hosted / VPS** (`ENABLE_IN_PROCESS_SCHEDULER=true`, the default):
  an in-process `time.Ticker` goroutine, since the process runs
  continuously there and a ticker is genuinely reliable.
- **Cloud Run** (`ENABLE_IN_PROCESS_SCHEDULER=false`, set by
  `deploy/gcp/deploy-api.sh`): **do not rely on the ticker** — confirmed by
  checking the actual logs, Cloud Run's scale-to-zero (the container can be
  torn down entirely while idle) and its default CPU throttling (CPU is
  frozen between requests, even on a warm instance) mean an in-process
  ticker only ever fires at container boot, never on its real schedule.
  Instead, two Google Cloud Scheduler jobs (free tier, provisioned by the
  same deploy script when `EDGE_SHARED_SECRET` and `CRON_SECRET` are set in
  the shell) call `POST /api/v1/internal/cron/billing-cycle` (every 24h)
  and `POST /api/v1/internal/cron/cloud-usage-poll` (hourly) directly,
  each carrying both `X-Edge-Secret` and `X-Cron-Secret`. This keeps the
  same "pay only for real work" cost profile scale-to-zero already gives
  the rest of the app — each scheduled hit is just one more cheap request
  — while guaranteeing the jobs actually run on schedule. See
  `services/api/internal/httpapi/cron_handlers.go`'s doc comment.

One-time setup on a fresh project (after `CRON_SECRET` exists in Secret
Manager per the pattern above):
```bash
gcloud services enable cloudscheduler.googleapis.com --project=$GCP_PROJECT_ID
EDGE_SHARED_SECRET=$(gcloud secrets versions access latest --secret=edge-shared-secret --project=$GCP_PROJECT_ID) \
CRON_SECRET=$(gcloud secrets versions access latest --secret=cron-secret --project=$GCP_PROJECT_ID) \
  deploy/gcp/deploy-api.sh
```

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
