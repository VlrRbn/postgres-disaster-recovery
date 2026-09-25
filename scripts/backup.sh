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

if (( $# != 1 )); then
    echo 'Usage: backup.sh {init|check|full|info|verify}' >&2
    exit 2
fi

case "$1" in
    init)
        pgbackrest stanza-create
        pgbackrest check
        ;;
    check)
        pgbackrest check
        ;;
    full)
        pgbackrest check
        pgbackrest --type=full backup
        verify_repository
        ;;
    info)
        pgbackrest info
        ;;
    verify)
        verify_repository
        ;;
    *)
        echo 'Usage: backup.sh {init|check|full|info|verify}' >&2
        exit 2
        ;;
esac
