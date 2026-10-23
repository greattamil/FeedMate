#!/usr/bin/env bash
# Deploys the api.<domain> reverse-proxy Worker (deploy/cloudflare/worker/).
#
# The origin hostname and custom-domain route live in worker/wrangler.toml
# (edit that file directly to migrate to a new Cloud Run origin or a
# different custom domain — see the comment at the top of that file).
# This script just runs `wrangler deploy` from the right directory and,
# optionally, sets the shared-secret Worker secret if EDGE_SHARED_SECRET is
# provided in the environment.
#
# Optional env var:
#   EDGE_SHARED_SECRET   if set, this script writes it as the Worker's
#                        EDGE_SHARED_SECRET secret (must match the value
#                        the API itself is configured with — see
#                        ../ENVIRONMENT.md). If unset, the script assumes
#                        the secret is already set from a previous run and
#                        only redeploys the Worker's code.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$SCRIPT_DIR/worker"

cd "$WORKER_DIR"

if [ -n "${EDGE_SHARED_SECRET:-}" ]; then
  echo "Setting Worker secret EDGE_SHARED_SECRET ..."
  printf '%s' "$EDGE_SHARED_SECRET" | wrangler secret put EDGE_SHARED_SECRET
fi

echo "Deploying Worker ..."
wrangler deploy
