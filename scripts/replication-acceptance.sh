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
        rm -f -- "$root/.local/replication-locks/$PGDR_REPLICATION_PROJECT.lock"
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
step() { printf '\n[%s/14] %s\n' "$1" "$2"; }

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

assert_tls() {
    local source=${1:-primary} replica=${2:-standby}
    [[ $(sql "$source" -Atc "SELECT count(*) FROM pg_stat_replication AS r
        JOIN pg_stat_ssl AS s USING (pid) WHERE r.application_name = '$replica'
        AND r.state = 'streaming' AND s.ssl AND s.version IN ('TLSv1.2', 'TLSv1.3');") == 1 ]]
    [[ $(sql "$replica" -Atc "SELECT current_setting('primary_conninfo') ~ 'sslmode=verify-full'
        AND current_setting('primary_conninfo') ~ 'sslrootcert=/var/lib/postgresql/tls/ca.crt';") == t ]]
}

replication_query() {
    "${compose[@]}" exec -T --user postgres standby psql -X --no-password \
        --dbname="$1" -Atc 'IDENTIFY_SYSTEM;'
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

verify_tls_guards() {
    step 2 'Verify encrypted streaming; reject plaintext, an untrusted CA and the wrong server name'
    local base container address node other mounts
    base='host=primary user=replicator dbname=replication replication=true passfile=/var/lib/postgresql/.pgpass connect_timeout=5'
    assert_tls
    replication_query "$base sslmode=verify-full sslrootcert=/var/lib/postgresql/tls/ca.crt" > /dev/null
    expect_failure 'no encryption' replication_query "$base sslmode=disable"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=untrusted-test-ca \
        -keyout "$work/untrusted.key" -out "$work/untrusted.crt" > /dev/null 2>&1
    chmod 0644 "$work/untrusted.crt"
    "${compose[@]}" cp "$work/untrusted.crt" standby:/tmp/untrusted-ca.crt
    expect_failure 'certificate verify failed' replication_query \
        "$base sslmode=verify-full sslrootcert=/tmp/untrusted-ca.crt"
    container=$("${compose[@]}" ps --quiet primary)
    address=$(docker inspect "$container" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
    expect_failure 'does not match host name' replication_query \
        "host=wrong-name.invalid hostaddr=$address user=replicator dbname=replication replication=true connect_timeout=5 sslmode=verify-full sslrootcert=/var/lib/postgresql/tls/ca.crt"
    for node in primary standby; do
        other=primary
        if [[ "$node" == primary ]]; then other=standby; fi
        container=$("${compose[@]}" ps --quiet "$node")
        mounts=$(docker inspect "$container" --format '{{range .Mounts}}{{println .Source}}{{end}}')
        if grep -Fxq "$work/tls/ca.key" <<< "$mounts" || grep -Fxq "$work/tls/$other.key" <<< "$mounts"; then
            echo "Node $node received an unrelated private key." >&2
            exit 1
        fi
        [[ $("${compose[@]}" exec -T --user postgres "$node" stat -c %a /var/lib/postgresql/tls/server.key) == 600 ]]
        [[ $(sql "$node" -Atc 'SHOW hba_file;') == /var/lib/postgresql/tls/pg_hba.conf ]]
    done
    echo 'PASS: verified TLS streaming; plaintext, untrusted CA and hostname mismatch rejected.'
}

verify_read_only() {
    step 3 'Reject writes on the standby with SQLSTATE 25006'
    if sql standby -v VERBOSITY=verbose -c "INSERT INTO orders (reference, amount_cents)
        VALUES ('standby-write-must-fail', 100);" > "$work/read-only.log" 2>&1; then
        echo 'Standby unexpectedly accepted a write.' >&2
        exit 1
    fi
    grep -q '25006' "$work/read-only.log"
}

verify_standby_catchup() {
    step 4 'Upgrade legacy connection settings on a retained standby and replay the missing writes'
    "${compose[@]}" stop standby
    sql primary -c "INSERT INTO orders (reference, amount_cents) VALUES ('during-standby-outage', 2100);"
    [[ $(sql primary -Atc "SELECT NOT active FROM pg_replication_slots WHERE slot_name = 'standby';") == t ]]
    # Simulate an existing pre-TLS standby; startup must upgrade it without reseeding.
    "${compose[@]}" run --rm --no-deps --user postgres --entrypoint bash standby \
        -c 'sed -i "s/sslmode=verify-full/sslmode=disable/" /var/lib/postgresql/data/postgresql.auto.conf'
    "${compose[@]}" up --no-build --detach --wait --wait-timeout 120 standby
    compare_orders
    assert_tls
}

verify_primary_outage() {
    step 5 'Keep the standby readable during a primary outage and reconnect afterwards'
    "${compose[@]}" stop primary
    [[ $(sql standby -Atc 'SELECT count(*) FROM orders;') == 21 ]]
    [[ $(sql standby -Atc 'SELECT pg_is_in_recovery();') == t ]]
    expect_failure 'current primary to be reachable and writable' env RESEED_NODE=standby \
        bash "$root/scripts/replication.sh" reseed
    "${compose[@]}" up --no-build --detach --wait --wait-timeout 120 primary
    sql primary -c "INSERT INTO orders (reference, amount_cents) VALUES ('after-primary-restart', 2200);"
    compare_orders
    assert_tls
}

verify_target_guard() {
    step 6 'Refuse a nonempty target without its standby marker'
    "${compose[@]}" stop standby
    "${compose[@]}" run --rm --no-deps --entrypoint bash standby \
        -c 'mv /var/lib/postgresql/data/standby.signal /var/lib/postgresql/data/standby.signal.saved'
    if "${compose[@]}" run --rm --no-deps standby > "$work/target-guard.log" 2>&1; then
        echo 'Standby unexpectedly started without standby.signal.' >&2
        exit 1
    fi
    grep -q 'refusing to overwrite or initialize' "$work/target-guard.log"
    expect_failure 'target must contain an existing standby' "${compose[@]}" run --rm --no-deps \
        --user postgres --entrypoint bash standby /opt/replication.sh reseed-check \
        "$(sql primary -Atc 'SELECT system_identifier FROM pg_control_system();')"
    "${compose[@]}" run --rm --no-deps --entrypoint bash standby \
        -c 'mv /var/lib/postgresql/data/standby.signal.saved /var/lib/postgresql/data/standby.signal'
}

verify_recreation() {
    step 7 'Recreate both containers on retained volumes and compare every stored field'
    "${compose[@]}" down
    "${compose[@]}" up --no-build --detach --wait --wait-timeout 120
    compare_orders
    assert_tls
    [[ $(sql standby -Atc 'SELECT count(*) FROM orders;') == 22 ]]
    local container
    for service in primary standby; do
        container=$("${compose[@]}" ps --quiet "$service")
        [[ $(docker inspect "$container" --format '{{len .HostConfig.PortBindings}}') == 0 ]]
    done
    echo 'PASS: 22 exact rows, asynchronous streaming, restricted replication role and read-only standby.'
    echo 'PASS: standby catch-up, primary outage/reconnection, unsafe-target rejection and volume persistence.'
}

verify_reseed_guards() {
    step 8 'Reject missing/wrong targets, healthy slots and unrelated data before reseeding'
    expect_failure 'Set RESEED_NODE=standby' env -u RESEED_NODE bash "$root/scripts/replication.sh" reseed
    expect_failure 'Set RESEED_NODE=standby' env RESEED_NODE=primary bash "$root/scripts/replication.sh" reseed
    expect_failure 'inactive lost physical slot' env RESEED_NODE=standby bash "$root/scripts/replication.sh" reseed
    expect_failure 'system identifiers differ' "${compose[@]}" run --rm --no-deps --user postgres \
        --entrypoint bash standby /opt/replication.sh reseed-check 1000000000000000000
    expect_failure 'Invalid reseed target' "${compose[@]}" run --rm --no-deps --user postgres \
        --env PGDATA=/tmp --entrypoint bash standby /opt/replication.sh reseed-check \
        "$(sql primary -Atc 'SELECT system_identifier FROM pg_control_system();')"
    compare_orders
}

lose_standby_wal() {
    local source=$1 replica=$2 deadline
    "${compose[@]}" stop "$replica"
    sql "$source" -c "DO \$\$ BEGIN
        FOR n IN 1..24 LOOP
            PERFORM pg_logical_emit_message(false, 'pgdr-acceptance', n::text);
            PERFORM pg_switch_wal();
        END LOOP;
        END \$\$; CHECKPOINT;"
    [[ $(sql "$source" -Atc "SELECT wal_status FROM pg_replication_slots WHERE slot_name = '$replica';") == lost ]]
    "${compose[@]}" up --no-build --no-deps --detach --wait --wait-timeout 120 "$replica"
    deadline=$((SECONDS + 30))
    until "${compose[@]}" logs --no-color "$replica" > "$work/wal-loss-$replica.log" 2>&1 &&
        grep -Eq 'requested WAL segment .* has already been removed|replication slot .* is invalidated' "$work/wal-loss-$replica.log"; do
        if (( SECONDS >= deadline )); then
            cat "$work/wal-loss-$replica.log" >&2
            echo 'Expected an explicit WAL-loss rejection after ordinary standby restart.' >&2
            exit 1
        fi
        sleep 1
    done
    [[ $(sql "$replica" -Atc 'SELECT count(*) FROM pg_stat_wal_receiver;') == 0 ]]
    "${compose[@]}" stop "$replica"
    "${compose[@]}" run --rm --no-deps --user postgres --entrypoint bash "$replica" \
        -c 'printf stale-copy > /var/lib/postgresql/data/reseed-old-copy'
}

verify_initial_reseed() {
    step 9 'Lose required WAL, reject an untrusted copy, then retry a verified standby reseed'
    local primary_started control_checksum
    primary_started=$(sql primary -Atc 'SELECT pg_postmaster_start_time();')
    lose_standby_wal primary standby
    control_checksum=$("${compose[@]}" run --rm --no-deps --user postgres --entrypoint bash standby \
        -c 'sha256sum /var/lib/postgresql/data/global/pg_control')
    cp "$work/tls/ca.crt" "$work/ca.saved"
    cp "$work/untrusted.crt" "$work/tls/ca.crt"
    expect_failure 'certificate verify failed' env RESEED_NODE=standby make --no-print-directory --directory="$root" replication-reseed
    [[ $("${compose[@]}" run --rm --no-deps --user postgres --entrypoint bash standby \
        -c 'sha256sum /var/lib/postgresql/data/global/pg_control') == "$control_checksum" ]]
    "${compose[@]}" run --rm --no-deps --user postgres --entrypoint bash standby \
        -c 'grep -Fxq stale-copy /var/lib/postgresql/data/reseed-old-copy'
    "${compose[@]}" rm --force standby
    expect_failure 'reseed is incomplete' "${compose[@]}" run --rm --no-deps standby
    expect_failure 'another database system' "${compose[@]}" run --rm --no-deps --user postgres \
        --entrypoint bash standby /opt/replication.sh reseed-check 1000000000000000000
    cp "$work/ca.saved" "$work/tls/ca.crt"
    RESEED_NODE=standby make --no-print-directory --directory="$root" replication-reseed
    [[ $(sql primary -Atc 'SELECT pg_postmaster_start_time();') == "$primary_started" ]]
    "${compose[@]}" exec -T --user postgres standby test ! -e /var/lib/postgresql/data/reseed-old-copy
    sql primary -c "INSERT INTO orders (reference, amount_cents) VALUES ('after-initial-reseed', 2500);"
    compare_orders
    assert_tls
    [[ $(sql primary -Atc "SELECT active AND wal_status IN ('reserved', 'extended') FROM pg_replication_slots WHERE slot_name = 'standby';") == t ]]
    echo 'PASS: real slot/WAL loss; failed TLS copy preserved old data; durable startup guard and explicit retry; primary stayed running.'
}

verify_promotion_guards() {
    step 10 'Reject premature rejoin and promotion while WAL replay is paused'
    expect_failure 'Rejoin requires a promoted standby' bash "$root/scripts/replication.sh" rejoin
    sql standby -c 'SELECT pg_wal_replay_pause();'
    expect_failure 'WAL replay is paused' bash "$root/scripts/replication.sh" switchover
    [[ $(sql primary -Atc 'SELECT pg_is_in_recovery();') == f ]]
    [[ $(sql standby -Atc 'SELECT pg_is_in_recovery();') == t ]]
    sql standby -c 'SELECT pg_wal_replay_resume();'
}

verify_promotion() {
    step 11 'Fence the old primary, promote the standby and accept a new write'
    local old_timeline new_timeline
    old_timeline=$(sql primary -Atc 'SELECT timeline_id FROM pg_control_checkpoint();')
    bash "$root/scripts/replication.sh" switchover
    [[ $(sql standby -Atc 'SELECT pg_is_in_recovery();') == f ]]
    expect_failure 'finish the current switchover first' env RESEED_NODE=primary bash "$root/scripts/replication.sh" reseed
    new_timeline=$(sql standby -Atc 'SELECT timeline_id FROM pg_control_checkpoint();')
    (( new_timeline > old_timeline ))
    expect_failure 'Old primary is fenced' "${compose[@]}" run --rm --no-deps primary
    bash "$root/scripts/replication.sh" up
    [[ $(docker inspect "$("${compose[@]}" ps --all --quiet primary)" --format '{{.State.Running}}') == false ]]
    sql standby -c "INSERT INTO orders (reference, amount_cents) VALUES ('after-promotion', 2300);"
    [[ $(sql standby -Atc 'SELECT count(*) FROM orders;') == 24 ]]
    "${compose[@]}" down
    bash "$root/scripts/replication.sh" up
    [[ $(sql standby -Atc "SELECT count(*) FROM orders WHERE reference = 'after-promotion';") == 1 ]]
}

verify_rejoin() {
    step 12 'Rewind the old primary offline and rejoin it as a read-only standby over TLS'
    bash "$root/scripts/replication.sh" rejoin
    [[ $(sql primary -Atc 'SELECT pg_is_in_recovery();') == t ]]
    [[ $(sql primary -Atc 'SHOW primary_slot_name;') == primary ]]
    sql standby -c "INSERT INTO orders (reference, amount_cents) VALUES ('after-rejoin', 2400);"
    compare_orders standby primary
    assert_tls standby primary
    expect_failure '25006' sql primary -v VERBOSITY=verbose \
        -c "INSERT INTO orders (reference, amount_cents) VALUES ('old-primary-write-must-fail', 100);"
}

verify_reversed_reseed() {
    step 13 'Reseed the current standby after roles reverse, preserving the writable service'
    local primary_started
    primary_started=$(sql standby -Atc 'SELECT pg_postmaster_start_time();')
    expect_failure 'Set RESEED_NODE=primary' env RESEED_NODE=standby bash "$root/scripts/replication.sh" reseed
    lose_standby_wal standby primary
    RESEED_NODE=primary make --no-print-directory --directory="$root" replication-reseed
    [[ $(sql standby -Atc 'SELECT pg_postmaster_start_time();') == "$primary_started" ]]
    "${compose[@]}" exec -T --user postgres primary test ! -e /var/lib/postgresql/data/reseed-old-copy
    sql standby -c "INSERT INTO orders (reference, amount_cents) VALUES ('after-reversed-reseed', 2600);"
    compare_orders standby primary
    assert_tls standby primary
    [[ $(sql standby -Atc "SELECT active AND wal_status IN ('reserved', 'extended') FROM pg_replication_slots WHERE slot_name = 'primary';") == t ]]
    echo 'PASS: reversed standby reseeded with verified TLS; writable service stayed running; new writes replicated.'
}

verify_switched_recreation() {
    step 14 'Resume the reversed topology and verify TLS and SQL commands follow roles'
    "${compose[@]}" down
    bash "$root/scripts/replication.sh" up
    compare_orders standby primary
    assert_tls standby primary
    [[ $(sql primary -Atc 'SELECT count(*) FROM orders;') == 26 ]]
    [[ $(sql primary -Atc 'SELECT pg_is_in_recovery();') == t ]]
    [[ $(sql standby -Atc 'SELECT pg_is_in_recovery();') == f ]]
    [[ $(bash "$root/scripts/replication.sh" primary-psql -Atc 'SELECT pg_is_in_recovery();') == f ]]
    [[ $(bash "$root/scripts/replication.sh" standby-psql -Atc 'SELECT pg_is_in_recovery();') == t ]]
    expect_failure 'already switched roles' bash "$root/scripts/replication.sh" switchover
    bash "$root/scripts/replication.sh" status
    echo 'PASS: controlled promotion, persisted fencing, offline pg_rewind, reversed streaming and 26 exact rows.'
}

verify_streaming
verify_tls_guards
verify_read_only
verify_standby_catchup
verify_primary_outage
verify_target_guard
verify_recreation
verify_reseed_guards
verify_initial_reseed
verify_promotion_guards
verify_promotion
verify_rejoin
verify_reversed_reseed
verify_switched_recreation
