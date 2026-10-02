#!/usr/bin/env bash
# Runs only inside the restore container, which mounts no primary data volume.
set -euo pipefail

if (( $# < 1 || $# > 2 )) || [[ ! "$1" =~ ^[0-9]{8}-[0-9]{6}F$ ]]; then
    echo 'Provide an explicit full backup label, for example 20260928-120000F.' >&2
    exit 2
fi

recovery_args=(--type=immediate --target-action=promote)
if (( $# == 2 )) && [[ "$2" == latest ]]; then
    recovery_args=(--type=default --target-timeline=current)
elif (( $# == 2 )); then
    if [[ ! "$2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?\+00:00$ ]] ||
        ! date --date="$2" +%s >/dev/null 2>&1; then
        echo 'Recovery time must be a valid UTC timestamp: YYYY-MM-DD HH:MM:SS[.ffffff]+00:00.' >&2
        exit 2
    fi
    # Time targets are inclusive by default in the pinned pgBackRest version.
    recovery_args=(--type=time "--target=$2" --target-timeline=current --target-action=promote)
fi

target=/var/lib/postgresql/data
if [[ -n $(find "$target" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    echo 'Restore target is not empty; refusing to overwrite existing data.' >&2
    exit 1
fi

exec pgbackrest --stanza=orders --set="$1" "${recovery_args[@]}" \
    --archive-mode=off restore
