#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
project=${PGDR_PROJECT:-postgres-dr-local}
if [[ ! "$project" =~ ^postgres-dr-[a-z0-9-]+$ ]]; then
    echo 'PGDR_PROJECT must start with postgres-dr- and use lowercase letters, digits or hyphens.' >&2
    exit 1
fi
export PGDR_SECRET_FILE=${PGDR_SECRET_FILE:-$root/.local/postgres_password}
exec docker compose --project-name "$project" --project-directory "$root" --file "$root/compose.yaml" "$@"
