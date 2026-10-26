#!/usr/bin/env bash
# Deploys the Go API (services/api) to Cloud Run, grants the two IAM
# roles the cloud-usage poller (internal/domain/cloudusage) needs to read
# live GCP Monitoring/Service-Usage data, and provisions the two Cloud
# Scheduler jobs that drive the combined billing-cycle/overdue-sweep and
# the cloud-usage poll — see
# services/api/internal/httpapi/cron_handlers.go's doc comment for why
# Cloud Scheduler is used instead of relying solely on the in-process
# ticker (it silently never fires on Cloud Run's scale-to-zero while idle).
# Only 2, deliberately, not 3 — see CronHandlers.RunDailyTasks's doc
# comment: Cloud Scheduler's Always Free tier is 3 jobs/billing account,
# and a 3rd logical job (the DB backup trigger) runs on a Cloudflare Cron
# Trigger instead, leaving a spare slot here.
#
# Nothing here is hardcoded to one GCP account/project — every
# account-specific value is an env var. To deploy to a different project,
# region, or service name, just set these differently; no script changes
# needed.
#
# Required env vars:
#   GCP_PROJECT_ID       e.g. project-29fdd88b-c856-4839-907
#   GCP_REGION           e.g. asia-south1 (pick a region close to your users —
#                         Cloud Run domain-mappings aren't supported in every
#                         region, which is why this stack uses a Cloudflare
#                         Worker reverse proxy instead; see ../cloudflare/worker)
#   CLOUD_RUN_SERVICE    e.g. feedmate-api
#
# Optional env vars:
#   PUBLIC_WEBSITE_TENANT_ID   pins the public, unauthenticated catalog
#                         endpoint (GET /api/v1/public/catalog, see
#                         httpapi.PublicHandlers) to one tenant — the
#                         marketing website's own tenant UUID, not a
#                         secret. Leave unset to disable that endpoint
#                         (it fails closed, 500, rather than guessing).
#
# Secrets are NOT set by this script — see ../ENVIRONMENT.md for how to
# create/mount them via GCP Secret Manager. Every production secret
# (DATABASE_URL, DATABASE_ADMIN_URL, JWT_SIGNING_KEY,
# SANDBOX_WEBHOOK_SECRET, EDGE_SHARED_SECRET, CRON_SECRET,
# CLOUDFLARE_API_TOKEN, AIVEN_API_TOKEN) lives in ONE consolidated JSON
# secret, "app-secrets", mounted as a file at APP_SECRETS_FILE — one
# Secret Manager secret/active-version total instead of six, well under
# its free tier of 6 active versions/account rather than sitting right at
# the line. This script only updates plain (non-secret) env vars, deploys
# the container, and provisions the Scheduler jobs; run the one-time
# secret-creation steps in ENVIRONMENT.md first on a fresh project.

set -euo pipefail

: "${GCP_PROJECT_ID:?Set GCP_PROJECT_ID}"
: "${GCP_REGION:?Set GCP_REGION}"
: "${CLOUD_RUN_SERVICE:?Set CLOUD_RUN_SERVICE}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_DIR="$SCRIPT_DIR/../../services/api"

# --max-instances is passed explicitly on every deploy, not left to
# Cloud Run's default, because the service also carries a separate,
# sticky top-level "default max instances" field (visible as
# metadata.annotations['run.googleapis.com/maxScale'], distinct from the
# per-revision autoscaling.knative.dev/maxScale that actually governs
# live traffic) which `gcloud run services update --max-instances`
# doesn't touch — found set to 3 from some earlier point in this
# project's history, worth never silently inheriting again. One
# instance is the deliberate choice: this is a low-traffic internal API,
# not something that needs to burst to multiple concurrent instances,
# and staying at 1 keeps Cloud Run cost trivially within the free tier.
echo "Deploying $CLOUD_RUN_SERVICE to $GCP_PROJECT_ID / $GCP_REGION ..."
gcloud run deploy "$CLOUD_RUN_SERVICE" \
  --source "$API_DIR" \
  --region="$GCP_REGION" \
  --project="$GCP_PROJECT_ID" \
  --max-instances=1 \
  --update-env-vars="GCP_PROJECT_ID=$GCP_PROJECT_ID,ENABLE_IN_PROCESS_SCHEDULER=false,FIREBASE_PROJECT_ID=$GCP_PROJECT_ID${PUBLIC_WEBSITE_TENANT_ID:+,PUBLIC_WEBSITE_TENANT_ID=$PUBLIC_WEBSITE_TENANT_ID}${PRODUCT_IMAGES_BASE_URL:+,PRODUCT_IMAGES_BASE_URL=$PRODUCT_IMAGES_BASE_URL}" \
  --quiet

# The service's own runtime identity needs read access to Cloud Monitoring
# and Service Usage for the cloud-usage poller's GCP metrics to populate —
# see internal/domain/cloudusage/poller_gcp.go. The runtime service account
# is <PROJECT_NUMBER>-compute@developer.gserviceaccount.com by default;
# resolve it dynamically rather than hardcoding a project number.
PROJECT_NUMBER="$(gcloud projects describe "$GCP_PROJECT_ID" --format='value(projectNumber)')"
RUNTIME_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

for ROLE in roles/monitoring.viewer roles/serviceusage.serviceUsageViewer roles/firebasecloudmessaging.admin; do
  echo "Granting $ROLE to $RUNTIME_SA ..."
  gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
    --member="serviceAccount:$RUNTIME_SA" \
    --role="$ROLE" \
    --condition=None \
    --quiet
done

SERVICE_URL="$(gcloud run services describe "$CLOUD_RUN_SERVICE" \
  --region="$GCP_REGION" --project="$GCP_PROJECT_ID" \
  --format='value(status.url)')"

# Cloud Scheduler jobs — only provisioned when both secrets are available
# in this shell's environment (they're not required env vars for this
# script, since most redeploys don't need to touch them). Run once on a
# fresh project after creating EDGE_SHARED_SECRET and CRON_SECRET per
# ../ENVIRONMENT.md; safe to re-run (uses `update`, falling back to
# `create` the first time).
# Only 2 jobs here, not 3 — billing-cycle and overdue-sweep are combined
# into one /internal/cron/daily-tasks call (see CronHandlers.RunDailyTasks's
# doc comment). A separate deploy/gcp/deploy-db-backup.sh adds a 3rd
# Scheduler job of its own (the daily DB backup trigger); together that's
# exactly 3, Cloud Scheduler's Always Free limit per billing account — a
# 4th would start incurring a real (if small) per-job charge.
if [ -n "${EDGE_SHARED_SECRET:-}" ] && [ -n "${CRON_SECRET:-}" ]; then
  HEADERS="X-Edge-Secret=$EDGE_SHARED_SECRET,X-Cron-Secret=$CRON_SECRET"

  for JOB in \
    "feedmate-daily-tasks|every 24 hours|$SERVICE_URL/api/v1/internal/cron/daily-tasks" \
    "feedmate-cloud-usage-poll|every 1 hours|$SERVICE_URL/api/v1/internal/cron/cloud-usage-poll"
  do
    IFS='|' read -r NAME SCHEDULE URL <<< "$JOB"
    echo "Provisioning Cloud Scheduler job $NAME ..."
    if gcloud scheduler jobs describe "$NAME" --project="$GCP_PROJECT_ID" --location="$GCP_REGION" >/dev/null 2>&1; then
      # `update http` takes --update-headers (not --headers, which only
      # `create http` accepts) — found the hard way: the first run of this
      # script against an already-provisioned job failed with "unrecognized
      # arguments: --headers=...".
      gcloud scheduler jobs update http "$NAME" \
        --project="$GCP_PROJECT_ID" --location="$GCP_REGION" \
        --schedule="$SCHEDULE" --uri="$URL" --http-method=POST --update-headers="$HEADERS" --quiet
    else
      gcloud scheduler jobs create http "$NAME" \
        --project="$GCP_PROJECT_ID" --location="$GCP_REGION" \
        --schedule="$SCHEDULE" --uri="$URL" --http-method=POST --headers="$HEADERS" --quiet
    fi
  done
else
  echo "Skipping Cloud Scheduler job provisioning (set EDGE_SHARED_SECRET and CRON_SECRET in this shell to provision/update them)."
fi

echo "Done. Service URL: $SERVICE_URL"
