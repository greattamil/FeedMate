#!/usr/bin/env bash
# One-time Firebase setup for push notifications (internal/domain/pushnotify).
# Not part of deploy-api.sh because these steps aren't idempotent/re-runnable
# the way a redeploy is — run this once per project, not on every deploy.
#
# Firebase stays on the free Spark plan throughout — no payment method is
# entered anywhere in this script. FCM itself is a genuinely free product
# regardless of plan (confirmed against Firebase's own pricing page) as
# long as sending happens from your own server (Cloud Run, here), not
# Cloud Functions.
#
# Requires: the Firebase CLI (`npm install -g firebase-tools`), logged in
# as a user with access to GCP_PROJECT_ID (`firebase login`).
#
# Required env vars:
#   GCP_PROJECT_ID        e.g. project-29fdd88b-c856-4839-907
#   ANDROID_PACKAGE_NAME  e.g. com.andipatti.feedmate_app

set -euo pipefail

: "${GCP_PROJECT_ID:?Set GCP_PROJECT_ID}"
: "${ANDROID_PACKAGE_NAME:?Set ANDROID_PACKAGE_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOOGLE_SERVICES_OUT="$SCRIPT_DIR/../../apps/flutter/android/app/google-services.json"

echo "Adding Firebase to GCP project $GCP_PROJECT_ID (idempotent if already added) ..."
firebase projects:addfirebase "$GCP_PROJECT_ID" || true

echo "Registering Android app $ANDROID_PACKAGE_NAME ..."
APP_ID="$(firebase apps:create ANDROID --package-name "$ANDROID_PACKAGE_NAME" --project "$GCP_PROJECT_ID" --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['appId'])" || true)"
if [ -z "$APP_ID" ]; then
  echo "App may already exist — looking it up ..."
  APP_ID="$(firebase apps:list ANDROID --project "$GCP_PROJECT_ID" --json 2>/dev/null | python3 -c "
import json, sys
apps = json.load(sys.stdin)['result']
for a in apps:
    if a['packageName'] == '$ANDROID_PACKAGE_NAME':
        print(a['appId'])
        break
")"
fi
: "${APP_ID:?Could not determine the Firebase Android app ID}"

echo "Downloading google-services.json -> $GOOGLE_SERVICES_OUT ..."
firebase apps:sdkconfig ANDROID "$APP_ID" --project "$GCP_PROJECT_ID" -o "$GOOGLE_SERVICES_OUT"

echo "Enabling the FCM API ..."
gcloud services enable fcm.googleapis.com --project="$GCP_PROJECT_ID"

echo "Done. google-services.json written — rebuild the Android app to pick it up."
echo "Note: the Cloud Run runtime service account still needs roles/firebasecloudmessaging.admin"
echo "to actually SEND pushes — deploy-api.sh grants this alongside its other IAM bindings."
