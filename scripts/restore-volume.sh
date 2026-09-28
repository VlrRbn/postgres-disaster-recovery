#!/usr/bin/env bash
# Runs only inside the restore container, which mounts no primary data volume.
set -euo pipefail

if (( $# != 1 )) || [[ ! "$1" =~ ^[0-9]{8}-[0-9]{6}F$ ]]; then
    echo 'Provide an explicit full backup label, for example 20260928-120000F.' >&2
    exit 2
fi

target=/var/lib/postgresql/data
if [[ -n $(find "$target" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    echo 'Restore target is not empty; refusing to overwrite existing data.' >&2
    exit 1
fi

exec pgbackrest --stanza=orders --set="$1" --type=immediate \
    --target-action=promote --archive-mode=off restore
