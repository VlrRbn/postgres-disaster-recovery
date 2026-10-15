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
step() { printf '\n[%s/6] %s\n' "$1" "$2"; }

wait_for_replay() {
    local target deadline=$((SECONDS + 60))
    target=$(sql primary -Atc 'SELECT pg_current_wal_lsn();')
    until [[ $(sql standby -Atc "SELECT pg_last_wal_replay_lsn() >= '$target'::pg_lsn;") == t ]]; do
        if (( SECONDS >= deadline )); then
            echo "Standby did not replay $target within 60 seconds." >&2
            exit 1
        fi
        sleep 1
    done
}

compare_orders() {
    wait_for_replay
    for service in primary standby; do
        sql "$service" -c 'COPY (SELECT * FROM orders ORDER BY id) TO STDOUT WITH CSV;' > "$work/$service.csv"
    done
    cmp "$work/primary.csv" "$work/standby.csv"
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

verify_streaming
verify_read_only
verify_standby_catchup
verify_primary_outage
verify_target_guard
verify_recreation
