#!/usr/bin/env bash
# Deploys the Go API (services/api) to Cloud Run, grants the two IAM
# roles the cloud-usage poller (internal/domain/cloudusage) needs to read
# live GCP Monitoring/Service-Usage data, and provisions the three Cloud
# Scheduler jobs that drive the billing cycle, cloud-usage poll, and
# overdue-payment sweep — see
# services/api/internal/httpapi/cron_handlers.go's doc comment for why
# Cloud Scheduler is used instead of relying solely on the in-process
# ticker (it silently never fires on Cloud Run's scale-to-zero while idle).
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
# Secrets (CLOUDFLARE_API_TOKEN, AIVEN_API_TOKEN, JWT_SIGNING_KEY,
# SANDBOX_WEBHOOK_SECRET, plus the consolidated db-credentials and
# internal-secrets JSON secrets carrying DATABASE_URL/DATABASE_ADMIN_URL
# and EDGE_SHARED_SECRET/CRON_SECRET) are NOT set by this script — see
# ../ENVIRONMENT.md for how to create/mount them via GCP Secret Manager
# (including why two of them are JSON files, not four separate secrets:
# staying within Secret Manager's 6-free-active-versions tier). This
# script only updates plain (non-secret) env vars, deploys the container,
# and provisions the Scheduler jobs; run the one-time secret-creation
# steps in ENVIRONMENT.md first on a fresh project.

set -euo pipefail

: "${GCP_PROJECT_ID:?Set GCP_PROJECT_ID}"
: "${GCP_REGION:?Set GCP_REGION}"
: "${CLOUD_RUN_SERVICE:?Set CLOUD_RUN_SERVICE}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_DIR="$SCRIPT_DIR/../../services/api"

echo "Deploying $CLOUD_RUN_SERVICE to $GCP_PROJECT_ID / $GCP_REGION ..."
gcloud run deploy "$CLOUD_RUN_SERVICE" \
  --source "$API_DIR" \
  --region="$GCP_REGION" \
  --project="$GCP_PROJECT_ID" \
  --update-env-vars="GCP_PROJECT_ID=$GCP_PROJECT_ID,ENABLE_IN_PROCESS_SCHEDULER=false,FIREBASE_PROJECT_ID=$GCP_PROJECT_ID" \
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
