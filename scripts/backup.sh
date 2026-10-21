#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compose=(bash "$root/scripts/compose.sh")

pgbackrest() {
    "${compose[@]}" exec -T --user postgres postgres pgbackrest --stanza=orders "$@"
}

verify_repository() {
    # pgBackRest 2.59.1 verify can return zero even when its report says error.
    # Also reject an empty repository, which has no completed backup to verify.
    pgbackrest --log-level-console=off --output=json info | python3 -c '
import json
import sys
info = json.load(sys.stdin)
if (len(info) != 1 or info[0]["name"] != "orders"
        or info[0]["status"]["code"] != 0 or not info[0]["backup"]):
    sys.exit("No healthy completed backup is available in stanza orders.")
'
    local report
    report=$(pgbackrest --log-level-console=off --output=text --verbose verify)
    printf '%s\n' "$report"
    if ! grep -Fxq 'status: ok' <<<"$report"; then
        echo 'Repository verification failed; inspect the pgBackRest report above.' >&2
        return 1
    fi
}

initialize_repository() {
    pgbackrest stanza-create
    pgbackrest check
}

create_full_backup() {
    pgbackrest check
    pgbackrest --type=full backup
    verify_repository
}

run_scheduled_job() {
    local target=$1 project=${PGDR_PROJECT:-postgres-dr-local}
    local timeout=${PGDR_SCHEDULE_LOCK_TIMEOUT_SECONDS:-300} result=0
    if [[ ${PGDR_REPOSITORY:-local} != local || ${PGDR_S3_FIXTURE:-0} != 0 ]]; then
        echo 'Scheduled jobs support the local backup repository only.' >&2
        exit 2
    fi
    if [[ ! "$project" =~ ^postgres-dr-[a-z0-9-]+$ || ! "$timeout" =~ ^[1-9][0-9]{0,3}$ ]] || (( timeout > 3600 )); then
        echo 'Use a valid postgres-dr-* project and a lock timeout of 1..3600 seconds.' >&2
        exit 2
    fi
    export PGDR_PROJECT="$project" PGDR_REPOSITORY=local PGDR_S3_FIXTURE=0
    mkdir -p "$root/.local/locks"
    # Both scheduled operations serialize on the same project lock; failures propagate.
    flock --exclusive --wait "$timeout" --conflict-exit-code 75 "$root/.local/locks/schedule-$project.lock" \
        make --no-print-directory --directory="$root" "$target" || result=$?
    if (( result == 75 )); then
        echo "Scheduled job could not acquire the $project lock within $timeout seconds." >&2
    elif (( result != 0 )); then
        echo "Scheduled $target failed with exit status $result; inspect the job output." >&2
    fi
    return "$result"
}

usage() {
    echo 'Usage: backup.sh {init|check|full|info|verify|scheduled-full|scheduled-health}' >&2
    exit 2
}

(( $# == 1 )) || usage

# Dispatch one operator command; verification is shared with full backup creation.
case "$1" in
    init)
        initialize_repository
        ;;
    check)
        pgbackrest check
        ;;
    full)
        create_full_backup
        ;;
    info)
        pgbackrest info
        ;;
    verify)
        verify_repository
        ;;
    scheduled-full)
        run_scheduled_job backup
        ;;
    scheduled-health)
        run_scheduled_job backup-health
        ;;
    *)
        usage
        ;;
esac
