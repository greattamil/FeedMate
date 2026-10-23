#!/usr/bin/env bash
# Builds the Flutter web app and deploys it to Cloudflare Pages.
#
# Required env vars:
#   API_BASE_URL        e.g. https://api.ramadas.me — baked into the build
#                        at compile time via --dart-define; see
#                        apps/flutter/lib/main.dart's _defaultApiBaseUrl().
#   CF_PAGES_PROJECT     e.g. feedmate — the Cloudflare Pages project name
#                        (create once via the Cloudflare dashboard or
#                        `wrangler pages project create`)

set -euo pipefail

: "${API_BASE_URL:?Set API_BASE_URL}"
: "${CF_PAGES_PROJECT:?Set CF_PAGES_PROJECT}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_DIR="$SCRIPT_DIR/../../apps/flutter"

cd "$FLUTTER_DIR"
echo "Building Flutter web with API_BASE_URL=$API_BASE_URL ..."
flutter build web --release --dart-define="API_BASE_URL=$API_BASE_URL"

echo "Deploying to Cloudflare Pages project '$CF_PAGES_PROJECT' ..."
wrangler pages deploy build/web --project-name="$CF_PAGES_PROJECT" --commit-dirty=true
