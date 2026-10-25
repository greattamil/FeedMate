#!/usr/bin/env bash
# Builds and deploys the feedmate-db-backup Cloud Run Job and grants it
# (and the main API's own runtime identity) the IAM it needs. Safe to
# re-run — every step is idempotent (create-or-update).
#
# This only covers the GCP side. The Cloudflare side (the Worker that
# schedules this job daily and receives its upload — see
# ../ENVIRONMENT.md's "Automated database backups" section for the full
# picture and why it's split this way) is deployed separately from
# ../cloudflare/db-backup/ via `wrangler deploy` + `wrangler secret put`.
#
# Why a Cloud Run Job and not a cron endpoint on the main API service:
# the API's own Dockerfile has no Postgres client tools (and shouldn't —
# it's a Go binary, not a shell toolbox), and a multi-hundred-MB pg_dump
# has no business running inside the request-serving container anyway. A
# separate Job with its own purpose-built image (deploy/backup/Dockerfile)
# keeps this fully isolated from the API's deploy/runtime path.
#
# Required env vars:
#   GCP_PROJECT_ID       e.g. project-29fdd88b-c856-4839-907
#   GCP_REGION            e.g. asia-south1
#   UPLOAD_URL             the Cloudflare Worker's URL, e.g.
#                          https://bpks-db-backup.<account>.workers.dev
#   UPLOAD_SECRET          must match the Worker's own UPLOAD_SECRET
#                          (`wrangler secret put UPLOAD_SECRET` from
#                          ../cloudflare/db-backup/)
#
# Assumes the db-credentials secret (JSON, "admin_url" field) already
# exists per ../ENVIRONMENT.md.

set -euo pipefail

: "${GCP_PROJECT_ID:?Set GCP_PROJECT_ID}"
: "${GCP_REGION:?Set GCP_REGION}"
: "${UPLOAD_URL:?Set UPLOAD_URL}"
: "${UPLOAD_SECRET:?Set UPLOAD_SECRET}"

JOB_NAME="feedmate-db-backup"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/../backup"
IMAGE="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/cloud-run-source-deploy/${JOB_NAME}:latest"

echo "Building backup image ..."
gcloud builds submit "$BACKUP_DIR" --tag="$IMAGE" --project="$GCP_PROJECT_ID" --quiet

# Keeps Artifact Registry's own storage within its free tier permanently
# — see ../ENVIRONMENT.md's "Keeping Artifact Registry itself inside the
# free tier". Idempotent; cheap to re-apply every deploy.
echo "Applying Artifact Registry cleanup policy ..."
gcloud artifacts repositories set-cleanup-policies cloud-run-source-deploy \
  --location="$GCP_REGION" --project="$GCP_PROJECT_ID" \
  --policy="$SCRIPT_DIR/artifact-cleanup-policy.json" --quiet

PROJECT_NUMBER="$(gcloud projects describe "$GCP_PROJECT_ID" --format='value(projectNumber)')"
JOB_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# backup.sh mounts the db-credentials JSON secret and parses admin_url out
# of it itself — the same secret the API already uses (see
# ../ENVIRONMENT.md), reused here read-only. The default compute service
# account already has secretmanager.secretAccessor on it (the API needs
# that too), so no new secret or IAM grant is needed for this.
echo "Deploying Cloud Run Job $JOB_NAME ..."
if gcloud run jobs describe "$JOB_NAME" --region="$GCP_REGION" --project="$GCP_PROJECT_ID" >/dev/null 2>&1; then
  gcloud run jobs update "$JOB_NAME" \
    --image="$IMAGE" \
    --region="$GCP_REGION" --project="$GCP_PROJECT_ID" \
    --set-env-vars="DB_CREDENTIALS_FILE=/secrets/db/db-credentials.json,UPLOAD_URL=$UPLOAD_URL,UPLOAD_SECRET=$UPLOAD_SECRET" \
    --set-secrets="/secrets/db/db-credentials.json=db-credentials:latest" \
    --task-timeout=900 --max-retries=1 \
    --quiet
else
  gcloud run jobs create "$JOB_NAME" \
    --image="$IMAGE" \
    --region="$GCP_REGION" --project="$GCP_PROJECT_ID" \
    --set-env-vars="DB_CREDENTIALS_FILE=/secrets/db/db-credentials.json,UPLOAD_URL=$UPLOAD_URL,UPLOAD_SECRET=$UPLOAD_SECRET" \
    --set-secrets="/secrets/db/db-credentials.json=db-credentials:latest" \
    --task-timeout=900 --max-retries=1 \
    --quiet
fi

# The API's own runtime identity (internal/domain/dbbackup.Trigger) needs
# permission to call this Job's jobs.run — that's how a Cloudflare Worker
# Cron Trigger ends up starting it (POST /internal/cron/trigger-db-backup
# -> this IAM grant lets the API call Cloud Run's own Admin API).
echo "Granting the API's own runtime identity permission to trigger this Job ..."
gcloud run jobs add-iam-policy-binding "$JOB_NAME" \
  --region="$GCP_REGION" --project="$GCP_PROJECT_ID" \
  --member="serviceAccount:$JOB_SA" --role="roles/run.invoker" --quiet

echo "Done."
echo "GCP side is ready. Now deploy the Cloudflare side if you haven't:"
echo "  cd ../cloudflare/db-backup && wrangler deploy"
echo "  wrangler secret put CRON_SECRET      # same value as the API's CRON_SECRET"
echo "  wrangler secret put UPLOAD_SECRET    # same value passed as UPLOAD_SECRET above"
echo ""
echo "Trigger one manually:"
echo "  gcloud run jobs execute $JOB_NAME --region=$GCP_REGION --project=$GCP_PROJECT_ID --wait"
