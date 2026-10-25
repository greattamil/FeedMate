#!/usr/bin/env bash
# Dumps the FeedMate Postgres database and uploads it to the Cloudflare
# Worker fronting the bpks-db-backups R2 bucket — see
# deploy/cloudflare/db-backup/worker.js. No Google Cloud Storage, no
# GCP storage SDK of any kind in this path: the only GCP touchpoint left
# for backups at all is this script's own compute (a Cloud Run Job,
# chosen because Cloudflare Workers can't run pg_dump — see
# internal/domain/dbbackup's doc comment on the Go side for the full
# reasoning), and that's already confirmed within the Always Free tier.
#
# Required (set by the Job definition, not baked into the image):
#   DB_CREDENTIALS_FILE   path to the mounted db-credentials JSON secret
#                         (the same secret the API itself uses — see
#                         deploy/ENVIRONMENT.md — reused here read-only so
#                         this job needs no secret of its own)
#   UPLOAD_URL            e.g. https://bpks-db-backup.sritamil-feedmate.workers.dev
#   UPLOAD_SECRET          bearer token the upload Worker requires —
#                         must match its own UPLOAD_SECRET (wrangler secret,
#                         deploy/cloudflare/db-backup/wrangler.toml)
set -euo pipefail

: "${DB_CREDENTIALS_FILE:?Set DB_CREDENTIALS_FILE}"
: "${UPLOAD_URL:?Set UPLOAD_URL}"
: "${UPLOAD_SECRET:?Set UPLOAD_SECRET}"

# No python3/jq in this image (postgres:18-trixie doesn't ship one, and
# pulling in a whole interpreter for one JSON field isn't worth it) — a
# plain grep/sed extraction is enough for this one flat string field.
DATABASE_ADMIN_URL="$(grep -oE '"admin_url":"[^"]*"' "$DB_CREDENTIALS_FILE" | sed -E 's/"admin_url":"([^"]*)"/\1/')"
if [ -z "$DATABASE_ADMIN_URL" ]; then
  echo "Failed to extract admin_url from $DB_CREDENTIALS_FILE" >&2
  exit 1
fi

# app_admin has no BYPASSRLS on the role itself — every tenant-owned
# table's RLS policy instead requires an explicit app.admin_mode=on
# session flag (db/migrations/0012_rls_policies.up.sql), set only by
# code paths that are deliberately, explicitly cross-tenant. pg_dump has
# no flag for setting arbitrary session GUCs, but respects PGOPTIONS the
# same way psql/libpq do.
export PGOPTIONS="-c app.admin_mode=on"

TIMESTAMP="$(date -u +%Y%m%d_%H%M%S)"
DUMP_FILE="/tmp/feedmate_backup_${TIMESTAMP}.dump"

echo "Starting pg_dump at ${TIMESTAMP} UTC ..."
# --enable-row-security: pg_dump defaults to requesting row_security=off
# (an unfiltered dump), which only superuser/BYPASSRLS roles may do —
# app_admin is neither (see PGOPTIONS comment above), so that default
# fails outright with "query would be affected by row-level security
# policy". This flag makes pg_dump instead dump through RLS as normal,
# which — combined with admin_mode=on making every table's policy
# permissive to app_admin — still yields a complete, every-tenant dump.
pg_dump "$DATABASE_ADMIN_URL" --format=custom --enable-row-security --file="$DUMP_FILE"

SIZE="$(stat -c%s "$DUMP_FILE")"
echo "Dump complete: ${DUMP_FILE} (${SIZE} bytes). Uploading to ${UPLOAD_URL} ..."

HTTP_STATUS="$(curl -sS -o /tmp/upload_response.json -w '%{http_code}' \
  -X PUT "${UPLOAD_URL%/}/feedmate_backup_${TIMESTAMP}.dump" \
  -H "Authorization: Bearer ${UPLOAD_SECRET}" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@${DUMP_FILE}")"

if [ "$HTTP_STATUS" != "200" ]; then
  echo "Upload failed (HTTP $HTTP_STATUS):"
  cat /tmp/upload_response.json
  exit 1
fi

rm -f "$DUMP_FILE"
echo "Backup uploaded: feedmate_backup_${TIMESTAMP}.dump"
