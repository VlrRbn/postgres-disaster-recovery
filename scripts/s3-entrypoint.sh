#!/usr/bin/env bash
set -euo pipefail

# Compose file secrets preserve host ownership; copy the 0600 input as root
# before the inherited PostgreSQL entrypoint drops to the database user.
install -d -o postgres -g postgres -m 0700 /etc/pgbackrest
install -o postgres -g postgres -m 0600 \
    /run/secrets/pgbackrest_s3 /etc/pgbackrest/pgbackrest.conf
exec /usr/local/bin/docker-entrypoint.sh "$@"
