#!/usr/bin/env bash
# Runs the PostgreSQL RLS tenant-isolation test suite against the local dev database.
# Usage: ./scripts/test-rls.sh
set -euo pipefail

CONTAINER="${FEEDMATE_PG_CONTAINER:-feedmate-postgres}"
DB="${FEEDMATE_DB:-feedmate}"

echo "Running RLS isolation tests against container '$CONTAINER'..."
docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 "postgres://app_admin:${APP_ADMIN_PASSWORD:-CHANGE_ME_IN_PRODUCTION}@localhost:5432/$DB" \
    -f - < tests/security/rls_isolation_test.sql

echo "RLS isolation tests completed successfully."
