#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
PGDR_PROJECT="postgres-dr-rpo-test-$(date +%s)-$$"
export PGDR_PROJECT
export PGDR_SECRET_FILE="$work/postgres_password"
compose=(bash "$root/scripts/compose.sh")
journal="$root/.local/reports/$PGDR_PROJECT-acknowledgments.jsonl"

cleanup() {
    local result=$?
    trap - EXIT
    if (( result != 0 )); then
        "${compose[@]}" --profile restore logs --no-color >&2 || true
    fi
    if "${compose[@]}" --profile restore down --volumes --remove-orphans; then
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
restore_sql() {
    "${compose[@]}" exec -T --user postgres restore \
        psql -X -v ON_ERROR_STOP=1 -U postgres -d orders "$@"
}
repository_snapshot() {
    "${compose[@]}" run --rm --no-deps --entrypoint sh --user postgres postgres -ec \
        'find /var/lib/pgbackrest -type f -exec sha256sum {} + | sort'
}

step() {
    printf '\n[%s/5] %s\n' "$1" "$2"
}

prepare_primary() {
    step 1 "Prepare a full backup and durable workload journal"
    bash "$root/scripts/setup.sh"
    "${compose[@]}" up --build --detach --wait --wait-timeout 120 postgres
    bash "$root/scripts/backup.sh" init
    [[ $(sql -Atc 'SHOW synchronous_commit;') == on ]]
    [[ $(sql -Atc 'SHOW fsync;') == on ]]
    bash "$root/scripts/backup.sh" full
    label=$("${compose[@]}" exec -T --user postgres postgres pgbackrest --stanza=orders \
        --log-level-console=off --output=json info |
        python3 -c 'import json
import sys; print(json.load(sys.stdin)[0]["backup"][0]["label"])')
    [[ "$label" =~ ^[0-9]{8}-[0-9]{6}F$ ]]
}

archive_initial_orders() {
    step 2 "Acknowledge five orders and verify their WAL delivery"
    python3 "$root/scripts/rpo_measurement.py" record --journal "$journal" --first 1 --count 5
    bash "$root/scripts/backup.sh" check
    last_archived_wal=$(sql -Atc 'SELECT last_archived_wal FROM pg_stat_archiver;')
    [[ "$last_archived_wal" =~ ^[0-9A-F]{24}$ ]]
    failed_before=$(sql -Atc 'SELECT failed_count FROM pg_stat_archiver;')
}

simulate_archive_outage_and_crash() {
    step 3 "Acknowledge five more orders during archive outage, then crash"
    # Restrict only this unique disposable repository: reads still work, archive writes fail.
    "${compose[@]}" exec -T --user postgres postgres chmod -R a-w /var/lib/pgbackrest/archive
    repository_snapshot >"$work/repository-before.sha256"
    python3 "$root/scripts/rpo_measurement.py" record --journal "$journal" --first 6 --count 5
    [[ $(sql -Atc 'SELECT count(*) FROM orders;') == 10 ]]
    sql -Atc 'SELECT pg_switch_wal();'
    for (( attempt=0; attempt<30; attempt++ )); do
        failed_after=$(sql -Atc 'SELECT failed_count FROM pg_stat_archiver;')
        if (( failed_after > failed_before )); then
            break
        fi
        sleep 1
    done
    (( failed_after > failed_before ))
    echo 'Confirmed: archiver failed while all 10 source orders remained committed.'
    python3 "$root/scripts/recovery_report.py" stamp "$work/fault.json"
    "${compose[@]}" kill --signal SIGKILL postgres
    source_id=$("${compose[@]}" ps --all --quiet postgres)
    [[ $(docker inspect --format '{{.State.ExitCode}}' "$source_id") == 137 ]]
    [[ -z $("${compose[@]}" ps --status running --quiet postgres) ]]
    repository_snapshot >"$work/repository-after-crash.sha256"
    cmp "$work/repository-before.sha256" "$work/repository-after-crash.sha256"
}

verify_recovered_data() {
    step 4 "Restore archived data and verify exact acknowledged rows"
    python3 "$root/scripts/recovery_report.py" stamp "$work/restore-start.json"
    BACKUP_LABEL="$label" bash "$root/scripts/restore.sh" latest
    [[ $(restore_sql -Atc 'SELECT pg_is_in_recovery();') == f ]]
    [[ $(restore_sql -Atc 'SHOW archive_mode;') == off ]]
    snapshot='COPY (SELECT id, reference, amount_cents, created_at FROM orders ORDER BY id) TO STDOUT WITH CSV;'
    restore_sql -c "$snapshot" >"$work/recovered.csv"
    # Compare all four fields against the host acknowledgment journal before timing ends.
    python3 - "$journal" "$work/recovered.csv" <<'PY'
import csv
import json
import sys
with open(sys.argv[1]) as source:
    expected = [json.loads(line)['row'] for line in source]
with open(sys.argv[2], newline='') as source:
    recovered = list(csv.reader(source))
assert len(expected) == 10 and recovered == expected[:5], 'Expected exact recovery of first five acknowledgments'
PY
    restore_sql -c "INSERT INTO orders (reference, amount_cents) VALUES ('rpo-restored-write', 5000);"
    [[ $(restore_sql -Atc "SELECT count(*) FROM orders WHERE reference = 'rpo-restored-write';") == 1 ]]
    python3 "$root/scripts/recovery_report.py" stamp "$work/restore-verified.json"
}

write_report() {
    step 5 "Verify isolation and record acknowledged loss and duration"
    restore_id=$("${compose[@]}" ps --quiet restore)
    docker inspect "$restore_id" >"$work/restore-container.json"
    python3 - "$work/restore-container.json" "$PGDR_PROJECT" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    container = json.load(source)[0]
mounts = {mount['Destination']: mount for mount in container['Mounts']}
assert mounts['/var/lib/postgresql/data']['Name'] == sys.argv[2] + '_pgrestore'
assert mounts['/var/lib/pgbackrest']['RW'] is False
assert all(mount.get('Name') != sys.argv[2] + '_pgdata' for mount in mounts.values())
assert container['HostConfig']['NetworkMode'] == 'none'
PY
    repository_snapshot >"$work/repository-after-restore.sha256"
    cmp "$work/repository-before.sha256" "$work/repository-after-restore.sha256"
    [[ -z $("${compose[@]}" ps --status running --quiet postgres) ]]
    python3 "$root/scripts/rpo_measurement.py" report --journal "$journal" \
        --recovered "$work/recovered.csv" --fault "$work/fault.json" \
        --start "$work/restore-start.json" --verified "$work/restore-verified.json" \
        --backup "$label" --project "$PGDR_PROJECT" --last-archived-wal "$last_archived_wal" \
        --output "$root/.local/reports/$PGDR_PROJECT-rpo.json"
    echo 'PASS: 10 acknowledged transactions, 5 recovered exactly, 5 lost after archive outage; source remained stopped.'
    echo 'PASS: recovered database accepts writes; archive contents unchanged; recovery storage and network isolated.'
}

# Run one complete disposable acceptance scenario.
prepare_primary
archive_initial_orders
simulate_archive_outage_and_crash
verify_recovered_data
write_report
