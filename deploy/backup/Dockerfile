# Image for the feedmate-db-backup Cloud Run Job: just pg_dump + curl.
#
# Uses the official postgres image as a base specifically so its bundled
# pg_dump version always matches the server it ships with — pg_dump
# refuses to dump a NEWER server than itself, and Aiven tracks current
# Postgres releases closely, so pinning a fixed Debian/PGDG client version
# here would eventually drift out of date again. If Aiven's major version
# changes, bump the tag below to match.
#
# No cloud SDK of any kind — the backup uploads to a Cloudflare Worker
# (deploy/cloudflare/db-backup/) over plain HTTPS via curl, not to any
# cloud provider's storage SDK.
FROM postgres:18-trixie

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY backup.sh /backup.sh
RUN chmod +x /backup.sh

ENTRYPOINT ["/backup.sh"]
