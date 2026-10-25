# Image for the feedmate-db-backup Cloud Run Job: pg_dump (client only,
# not the full Postgres server) + curl.
#
# Deliberately NOT based on postgres:18-trixie (the official image bundles
# the full server — initdb, postgres daemon, etc. — none of which this
# job ever runs) — that was a real, measured mistake: it alone pushed
# this repo's total Artifact Registry storage over the 0.5GB free tier
# with no deletion able to claw it back (the bytes are in shared layers
# still referenced by every kept version). A plain Debian base with just
# the client package is a fraction of the size and still gets exact
# client/server version matching via the official PostgreSQL apt repo
# (PGDG) — Aiven tracks current Postgres releases, and pg_dump refuses to
# dump a newer server than itself, so the client version must stay
# current; bump the package name below if Aiven's major version changes.
FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates gnupg \
    && install -d /usr/share/postgresql-common/pgdg \
    && curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo "$VERSION_CODENAME")-pgdg main" \
         > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client-18 \
    && apt-get purge -y gnupg \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

COPY backup.sh /backup.sh
RUN chmod +x /backup.sh

ENTRYPOINT ["/backup.sh"]
