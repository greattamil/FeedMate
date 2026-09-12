#!/usr/bin/env bash
# Runs Go integration tests against the local dev Postgres (must already be
# migrated — see scripts/test-rls.sh's companion migration step, or:
#   docker compose -f deploy/compose/docker-compose.yml --profile migrate run --rm migrate
set -euo pipefail

export DATABASE_URL="${DATABASE_URL:-postgres://app_user:CHANGE_ME_IN_PRODUCTION@localhost:5432/feedmate?sslmode=disable}"
export DATABASE_ADMIN_URL="${DATABASE_ADMIN_URL:-postgres://app_admin:CHANGE_ME_IN_PRODUCTION@localhost:5432/feedmate?sslmode=disable}"

cd "$(dirname "$0")/../services/api"
go test -tags=integration -count=1 ./... -v
