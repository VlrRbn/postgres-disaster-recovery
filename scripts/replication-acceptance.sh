#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
PGDR_REPLICATION_PROJECT="postgres-dr-replication-test-$(date +%s)-$$"
export PGDR_REPLICATION_PROJECT
export PGDR_REPLICATION_DIR="$work"
compose=(bash "$root/scripts/compose.sh" --replication)

cleanup() {
    local result=$?
    trap - EXIT
    if (( result != 0 )); then
        "${compose[@]}" logs --no-color >&2 || true
    fi
    if "${compose[@]}" down --volumes --remove-orphans; then
        rm -rf -- "$work"
    else
        echo "Cleanup failed for $PGDR_REPLICATION_PROJECT; secrets retained at $work." >&2
        result=1
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sql() {
    local service=$1
    shift
    "${compose[@]}" exec -T --user postgres "$service" \
        psql -X -v ON_ERROR_STOP=1 -U postgres -d orders "$@"
}
step() { printf '\n[%s/10] %s\n' "$1" "$2"; }

wait_for_replay() {
    local source=${1:-primary} replica=${2:-standby} target deadline=$((SECONDS + 60))
    target=$(sql "$source" -Atc 'SELECT pg_current_wal_lsn();')
    until [[ $(sql "$replica" -Atc "SELECT pg_last_wal_replay_lsn() >= '$target'::pg_lsn;") == t ]]; do
        if (( SECONDS >= deadline )); then
            echo "Standby did not replay $target within 60 seconds." >&2
            exit 1
        fi
        sleep 1
    done
}

compare_orders() {
    local source=${1:-primary} replica=${2:-standby}
    wait_for_replay "$source" "$replica"
    for service in primary standby; do
        sql "$service" -c 'COPY (SELECT * FROM orders ORDER BY id) TO STDOUT WITH CSV;' > "$work/$service.csv"
    done
    cmp "$work/primary.csv" "$work/standby.csv"
}

expect_failure() {
    local message=$1
    shift
    if "$@" > "$work/rejected.log" 2>&1; then
        echo "Unexpected success; expected: $message" >&2
        exit 1
    fi
    grep -q "$message" "$work/rejected.log"
}

verify_streaming() {
    step 1 'Start an isolated primary and seed the standby'
    bash "$root/scripts/replication.sh" up
    [[ $(sql primary -Atc 'SELECT pg_is_in_recovery();') == f ]]
    [[ $(sql standby -Atc 'SELECT pg_is_in_recovery();') == t ]]
    sql primary -c "INSERT INTO orders (reference, amount_cents)
        SELECT 'replication-' || n, n * 100 FROM generate_series(1, 20) AS n;"
    compare_orders
    [[ $(sql primary -Atc "SELECT count(*) FROM pg_stat_replication
        WHERE application_name = 'standby' AND state = 'streaming' AND sync_state = 'async';") == 1 ]]
    [[ $(sql primary -Atc "SELECT count(*) FROM pg_roles WHERE rolname = 'replicator'
        AND rolreplication AND rolcanlogin AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole;") == 1 ]]
    [[ $(sql primary -Atc "SELECT setting FROM pg_settings WHERE name = 'max_slot_wal_keep_size';") == 256 ]]
}

verify_read_only() {
    step 2 'Reject writes on the standby with SQLSTATE 25006'
    if sql standby -v VERBOSITY=verbose -c "INSERT INTO orders (reference, amount_cents)
        VALUES ('standby-write-must-fail', 100);" > "$work/read-only.log" 2>&1; then
        echo 'Standby unexpectedly accepted a write.' >&2
        exit 1
    fi
    grep -q '25006' "$work/read-only.log"
}

verify_standby_catchup() {
    step 3 'Retain WAL while the standby is stopped, then replay the missing writes'
    "${compose[@]}" stop standby
    sql primary -c "INSERT INTO orders (reference, amount_cents) VALUES ('during-standby-outage', 2100);"
    [[ $(sql primary -Atc "SELECT NOT active FROM pg_replication_slots WHERE slot_name = 'standby';") == t ]]
    "${compose[@]}" up --no-build --detach --wait --wait-timeout 120 standby
    compare_orders
}

verify_primary_outage() {
    step 4 'Keep the standby readable during a primary outage and reconnect afterwards'
    "${compose[@]}" stop primary
    [[ $(sql standby -Atc 'SELECT count(*) FROM orders;') == 21 ]]
    [[ $(sql standby -Atc 'SELECT pg_is_in_recovery();') == t ]]
    "${compose[@]}" up --no-build --detach --wait --wait-timeout 120 primary
    sql primary -c "INSERT INTO orders (reference, amount_cents) VALUES ('after-primary-restart', 2200);"
    compare_orders
}

verify_target_guard() {
    step 5 'Refuse a nonempty target without its standby marker'
    "${compose[@]}" stop standby
    "${compose[@]}" run --rm --no-deps --entrypoint bash standby \
        -c 'mv /var/lib/postgresql/data/standby.signal /var/lib/postgresql/data/standby.signal.saved'
    if "${compose[@]}" run --rm --no-deps standby > "$work/target-guard.log" 2>&1; then
        echo 'Standby unexpectedly started without standby.signal.' >&2
        exit 1
    fi
    grep -q 'refusing to overwrite or initialize' "$work/target-guard.log"
    "${compose[@]}" run --rm --no-deps --entrypoint bash standby \
        -c 'mv /var/lib/postgresql/data/standby.signal.saved /var/lib/postgresql/data/standby.signal'
}

verify_recreation() {
    step 6 'Recreate both containers on retained volumes and compare every stored field'
    "${compose[@]}" down
    "${compose[@]}" up --no-build --detach --wait --wait-timeout 120
    compare_orders
    [[ $(sql standby -Atc 'SELECT count(*) FROM orders;') == 22 ]]
    local container
    for service in primary standby; do
        container=$("${compose[@]}" ps --quiet "$service")
        [[ $(docker inspect "$container" --format '{{len .HostConfig.PortBindings}}') == 0 ]]
    done
    echo 'PASS: 22 exact rows, asynchronous streaming, restricted replication role and read-only standby.'
    echo 'PASS: standby catch-up, primary outage/reconnection, unsafe-target rejection and volume persistence.'
}

verify_promotion_guards() {
    step 7 'Reject premature rejoin and promotion while WAL replay is paused'
    expect_failure 'Rejoin requires a promoted standby' bash "$root/scripts/replication.sh" rejoin
    sql standby -c 'SELECT pg_wal_replay_pause();'
    expect_failure 'WAL replay is paused' bash "$root/scripts/replication.sh" promote
    [[ $(sql primary -Atc 'SELECT pg_is_in_recovery();') == f ]]
    [[ $(sql standby -Atc 'SELECT pg_is_in_recovery();') == t ]]
    sql standby -c 'SELECT pg_wal_replay_resume();'
}

verify_promotion() {
    step 8 'Fence the old primary, promote the standby and accept a new write'
    local old_timeline new_timeline
    old_timeline=$(sql primary -Atc 'SELECT timeline_id FROM pg_control_checkpoint();')
    bash "$root/scripts/replication.sh" promote
    [[ $(sql standby -Atc 'SELECT pg_is_in_recovery();') == f ]]
    new_timeline=$(sql standby -Atc 'SELECT timeline_id FROM pg_control_checkpoint();')
    (( new_timeline > old_timeline ))
    expect_failure 'Old primary is fenced' "${compose[@]}" run --rm --no-deps primary
    bash "$root/scripts/replication.sh" up
    [[ $(docker inspect "$("${compose[@]}" ps --all --quiet primary)" --format '{{.State.Running}}') == false ]]
    sql standby -c "INSERT INTO orders (reference, amount_cents) VALUES ('after-promotion', 2300);"
    [[ $(sql standby -Atc 'SELECT count(*) FROM orders;') == 23 ]]
    "${compose[@]}" down
    bash "$root/scripts/replication.sh" up
    [[ $(sql standby -Atc "SELECT count(*) FROM orders WHERE reference = 'after-promotion';") == 1 ]]
}

verify_rejoin() {
    step 9 'Rewind the old primary offline and rejoin it as a read-only standby'
    bash "$root/scripts/replication.sh" rejoin
    [[ $(sql primary -Atc 'SELECT pg_is_in_recovery();') == t ]]
    [[ $(sql primary -Atc 'SHOW primary_slot_name;') == primary ]]
    sql standby -c "INSERT INTO orders (reference, amount_cents) VALUES ('after-rejoin', 2400);"
    compare_orders standby primary
    expect_failure '25006' sql primary -v VERBOSITY=verbose \
        -c "INSERT INTO orders (reference, amount_cents) VALUES ('old-primary-write-must-fail', 100);"
}

verify_switched_recreation() {
    step 10 'Resume the reversed topology and verify the SQL commands follow roles'
    "${compose[@]}" down
    bash "$root/scripts/replication.sh" up
    compare_orders standby primary
    [[ $(sql primary -Atc 'SELECT count(*) FROM orders;') == 24 ]]
    [[ $(sql primary -Atc 'SELECT pg_is_in_recovery();') == t ]]
    [[ $(sql standby -Atc 'SELECT pg_is_in_recovery();') == f ]]
    [[ $(bash "$root/scripts/replication.sh" primary-psql -Atc 'SELECT pg_is_in_recovery();') == f ]]
    [[ $(bash "$root/scripts/replication.sh" standby-psql -Atc 'SELECT pg_is_in_recovery();') == t ]]
    expect_failure 'already switched roles' bash "$root/scripts/replication.sh" promote
    bash "$root/scripts/replication.sh" status
    echo 'PASS: controlled promotion, persisted fencing, offline pg_rewind, reversed streaming and 24 exact rows.'
}

verify_streaming
verify_read_only
verify_standby_catchup
verify_primary_outage
verify_target_guard
verify_recreation
verify_promotion_guards
verify_promotion
verify_rejoin
verify_switched_recreation
