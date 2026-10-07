#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
PGDR_PROJECT="postgres-dr-health-test-$(date +%s)-$$"
export PGDR_PROJECT
export PGDR_SECRET_FILE="$work/postgres_password"
# Explicit limits keep the scenario independent of interactive operator settings.
export PGDR_BACKUP_MAX_AGE_SECONDS=86400
export PGDR_ARCHIVE_TIMEOUT_SECONDS=5
compose=(bash "$root/scripts/compose.sh")

cleanup() {
    local result=$?
    trap - EXIT
    if (( result != 0 )); then
        "${compose[@]}" logs --no-color >&2 || true
    fi
    if "${compose[@]}" down --volumes --remove-orphans; then
        rm -rf -- "$work"
    else
        echo "Cleanup failed for $PGDR_PROJECT; secret retained at $PGDR_SECRET_FILE." >&2
        result=1
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sql() {
    "${compose[@]}" exec -T --user postgres postgres \
        psql -X -v ON_ERROR_STOP=1 -U postgres -d orders "$@"
}
expect_health() {
    local scenario=$1 expected=$2 result=0
    shift 2
    env "$@" python3 "$root/scripts/backup_health.py" >"$work/$scenario.json" || result=$?
    if (( result != expected )); then
        cat "$work/$scenario.json" >&2
        echo "Expected $scenario exit $expected; got $result." >&2
        exit 1
    fi
}

step() {
    printf '\n[%s/6] %s\n' "$1" "$2"
}

prepare_primary() {
    step 1 "Start a primary and detect missing repository metadata"
    bash "$root/scripts/setup.sh"
    "${compose[@]}" up --build --detach --wait --wait-timeout 120 postgres
    expect_health uninitialized 1
}

verify_backup_freshness() {
    step 2 "Detect missing and stale backups; accept a fresh full copy"
    bash "$root/scripts/backup.sh" init
    expect_health empty 1

    sql -c "INSERT INTO orders (reference, amount_cents) VALUES ('health-preserved', 100);"
    bash "$root/scripts/backup.sh" full
    expect_health healthy 0

    # Let a real completed backup exceed a deliberately short limit; metadata is untouched.
    sleep 2
    expect_health stale 1 PGDR_BACKUP_MAX_AGE_SECONDS=1
}

verify_archive_outage() {
    step 3 "Detect failed WAL delivery with a fresh backup available"
    # Only this unique disposable archive is restricted; backups remain readable.
    "${compose[@]}" exec -T --user postgres postgres chmod -R a-w /var/lib/pgbackrest/archive
    expect_health archive-outage 1
}

verify_archive_recovery() {
    step 4 "Restore WAL delivery without clearing historical errors"
    "${compose[@]}" exec -T --user postgres postgres chmod -R u+w /var/lib/pgbackrest/archive
    # Restart wakes the archiver immediately instead of waiting for its retry interval.
    "${compose[@]}" restart postgres
    "${compose[@]}" up --no-build --detach --wait --wait-timeout 120 postgres
    expect_health recovered 0
    [[ $(sql -Atc "SELECT count(*) FROM orders WHERE reference = 'health-preserved' AND amount_cents = 100;") == 1 ]]
}

verify_stopped_primary() {
    step 5 "Report an unavailable primary as unhealthy JSON"
    "${compose[@]}" stop postgres
    expect_health stopped 1
}

write_report() {
    step 6 "Validate every health result and save the acceptance report"
    python3 - "$work" "$root/.local/reports/$PGDR_PROJECT-health.json" "$PGDR_PROJECT" <<'PY'
import json
from pathlib import Path
import sys

work, output = map(Path, sys.argv[1:3])
reports = {name: json.loads((work / f'{name}.json').read_text()) for name in
           ('uninitialized', 'empty', 'healthy', 'stale', 'archive-outage', 'recovered', 'stopped')}
for name in ('uninitialized', 'empty'):
    assert reports[name]['checks']['backup_freshness']['status'] == 'failed', name
assert reports['empty']['checks']['wal_delivery']['status'] == 'ok'
assert reports['healthy']['status'] == 'healthy'
assert reports['stale']['checks']['backup_freshness']['status'] == 'failed'
assert reports['stale']['checks']['wal_delivery']['status'] == 'ok'
outage = reports['archive-outage']
assert outage['checks']['backup_freshness']['status'] == 'ok'
assert outage['checks']['wal_delivery']['status'] == 'failed'
assert outage['archiver']['failed_count'] > reports['healthy']['archiver']['failed_count']
assert reports['recovered']['status'] == 'healthy'
assert reports['recovered']['archiver']['failed_count'] >= outage['archiver']['failed_count']
assert reports['recovered']['archiver']['failed_count'] > 0
assert reports['recovered']['checks']['backup_freshness']['label'] == reports['healthy']['checks']['backup_freshness']['label']
assert reports['stopped']['status'] == 'unhealthy'
assert all(check['status'] == 'failed' for check in reports['stopped']['checks'].values())
output.parent.mkdir(parents=True, exist_ok=True)
with output.open('x') as out:
    json.dump({'schema_version': 1, 'status': 'verified', 'project': sys.argv[3],
               'scenario': 'backup_health_detection', 'reports': reports}, out, indent=2)
    out.write('\n')
print(f'Backup health acceptance report: {output}')
PY
    echo 'PASS: missing metadata and backups, stale backup, archive outage and stopped primary detected.'
    echo 'PASS: healthy backup and WAL delivery verified; recovered archiver accepts historical failures.'
}

# Run one complete disposable acceptance scenario.
prepare_primary
verify_backup_freshness
verify_archive_outage
verify_archive_recovery
verify_stopped_primary
write_report
