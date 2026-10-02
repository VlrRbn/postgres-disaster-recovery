#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compose=(bash "$root/scripts/compose.sh")
wait_seconds=${RESTORE_WAIT_SECONDS:-120}
if [[ ! "$wait_seconds" =~ ^[1-9][0-9]{0,2}$ ]] || (( wait_seconds < 10 || wait_seconds > 300 )); then
    echo 'RESTORE_WAIT_SECONDS must be an integer from 10 to 300.' >&2
    exit 2
fi

start_restore() {
    if ! "${compose[@]}" up --no-build --pull never --no-deps --detach \
        --wait --wait-timeout "$wait_seconds" restore; then
        "${compose[@]}" logs --no-color restore >&2 || true
        return 1
    fi
    echo 'Restore database is ready and out of recovery; archive_mode is disabled.'
}

case "${1:-}" in
    restore|time|latest)
        label=${BACKUP_LABEL:-}
        if [[ ! "$label" =~ ^[0-9]{8}-[0-9]{6}F$ ]]; then
            echo 'Set BACKUP_LABEL to an explicit full backup label from make backup-info.' >&2
            exit 2
        fi
        restore_args=("$label")
        if [[ "$1" == time ]]; then
            recovery_time=${RECOVERY_TIME:-}
            if [[ ! "$recovery_time" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?\+00:00$ ]] ||
                ! date --date="$recovery_time" +%s >/dev/null 2>&1; then
                echo 'Set RECOVERY_TIME to a valid UTC timestamp: YYYY-MM-DD HH:MM:SS[.ffffff]+00:00.' >&2
                exit 2
            fi
            restore_args+=("$recovery_time")
        fi
        if [[ "$1" == latest ]]; then
            restore_args+=(latest)
        fi
        if [[ -n $("${compose[@]}" ps --all --quiet restore) ]]; then
            echo 'Restore container already exists. Use make restore-up to resume or make restore-down to remove it.' >&2
            exit 1
        fi
        "${compose[@]}" build restore
        "${compose[@]}" run --rm --no-deps --entrypoint bash restore /opt/restore-volume.sh "${restore_args[@]}"
        start_restore
        ;;
    start)
        start_restore
        ;;
    *)
        echo 'Usage: restore.sh {restore|time|latest|start}' >&2
        exit 2
        ;;
esac
