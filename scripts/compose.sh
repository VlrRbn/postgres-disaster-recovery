#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# Select the configuration and defaults for one isolated runtime.
case "${PGDR_REPOSITORY:-local}" in
    local)
        project=${PGDR_PROJECT:-postgres-dr-local}
        config="$root/compose.yaml"
        export PGDR_SECRET_FILE=${PGDR_SECRET_FILE:-$root/.local/postgres_password}
        ;;
    s3)
        project=${PGDR_PROJECT:-postgres-dr-s3}
        if [[ ! "$project" =~ ^postgres-dr-s3($|-[a-z0-9-]+$) ]]; then
            echo 'S3 mode requires PGDR_PROJECT=postgres-dr-s3 or a postgres-dr-s3-* project.' >&2
            exit 2
        fi
        config="$root/compose.s3.yaml"
        export PGDR_S3_DIR=${PGDR_S3_DIR:-$root/.local/s3}
        export PGDR_SECRET_FILE=${PGDR_SECRET_FILE:-$PGDR_S3_DIR/postgres_password}
        ;;
    *) echo 'PGDR_REPOSITORY must be local or s3.' >&2; exit 2 ;;
esac
# Validate the project before forwarding any operator command to Docker.
if [[ ! "$project" =~ ^postgres-dr-[a-z0-9-]+$ ]]; then
    echo 'PGDR_PROJECT must start with postgres-dr- and use lowercase letters, digits or hyphens.' >&2
    exit 1
fi
exec docker compose --project-name "$project" --project-directory "$root" --file "$config" "$@"
