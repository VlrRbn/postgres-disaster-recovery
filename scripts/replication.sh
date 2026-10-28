#!/usr/bin/env bash
set -euo pipefail

control=/var/lib/pgdr-control
tls=/var/lib/postgresql/tls
tls_options=(-c ssl=on -c "ssl_cert_file=$tls/server.crt" -c "ssl_key_file=$tls/server.key"
    -c ssl_min_protocol_version=TLSv1.2 -c "hba_file=$tls/pg_hba.conf")
die() { echo "$*" >&2; exit 1; }

prepare_container() {
    install -d -o postgres -g postgres -m 0700 "$control"
    install -d -o postgres -g postgres -m 0700 "$tls"
    install -o postgres -g postgres -m 0600 /run/secrets/replication_key "$tls/server.key"
    install -o postgres -g postgres -m 0644 /run/secrets/replication_cert "$tls/server.crt"
    install -o postgres -g postgres -m 0644 /run/secrets/replication_ca "$tls/ca.crt"
    # Keep managed authentication outside PGDATA, including upgraded and rewound volumes.
    cat > "$tls/pg_hba.conf" <<'HBA'
local all all trust
hostssl replication replicator samenet scram-sha-256
host replication all all reject
host all all all reject
HBA
    chown postgres:postgres "$tls/pg_hba.conf"
    chmod 0600 "$tls/pg_hba.conf"
}

topology() {
    if [[ -f "$control/primary-rejoined" ]]; then echo rejoined
    elif [[ -f "$control/standby-promoted" ]]; then echo promoted
    elif [[ -f "$control/primary-fenced" ]]; then echo fenced
    else echo initial
    fi
}

# The official image sources non-executable init scripts on the first startup.
initialize_primary() {
    psql -X -v ON_ERROR_STOP=1 -U postgres -d orders <<'SQL'
DO $$
BEGIN
    EXECUTE format('CREATE ROLE replicator WITH LOGIN REPLICATION PASSWORD %L',
                   rtrim(pg_read_file('/var/lib/postgresql/.replication_password'), E'\n'));
END $$;
SELECT pg_create_physical_replication_slot('standby', true);
SQL
    rm /var/lib/postgresql/.replication_password
}

start_primary() {
    prepare_container
    if [[ -f "$control/primary-fenced" ]]; then
        [[ -f "$control/primary-rejoined" && -f "$PGDATA/standby.signal" ]] ||
            die 'Old primary is fenced; use make replication-rejoin before starting it.'
        start_standby
    fi
    [[ ! -f "$PGDATA/standby.signal" ]] || die 'Unexpected standby data on the original primary; inspect the control volume.'
    install -o postgres -g postgres -m 0600 /run/secrets/replication_password \
        /var/lib/postgresql/.replication_password
    exec /usr/local/bin/docker-entrypoint.sh "$@" "${tls_options[@]}"
}

configure_recovery_connection() {
    local node=${PGDR_NODE:-standby} upstream=primary
    if [[ "$node" == primary ]]; then upstream=standby; fi
    # Replace legacy sslmode=disable settings without accumulating duplicate overrides.
    sed -i -E '/^[[:space:]]*(primary_conninfo|primary_slot_name|recovery_target_timeline)[[:space:]]*=/d' \
        "$PGDATA/postgresql.auto.conf"
    cat >> "$PGDATA/postgresql.auto.conf" <<CONF
primary_conninfo = 'host=$upstream user=replicator application_name=$node passfile=/var/lib/postgresql/.pgpass connect_timeout=5 sslmode=verify-full sslrootcert=$tls/ca.crt'
primary_slot_name = '$node'
recovery_target_timeline = 'latest'
CONF
}

start_standby() {
    if [[ $(id -u) == 0 ]]; then
        prepare_container
        local password upstream=primary
        if [[ ${PGDR_NODE:-standby} == primary ]]; then upstream=standby; fi
        password=$(cat /run/secrets/replication_password)
        password=${password//\\/\\\\}
        password=${password//:/\\:}
        umask 077
        printf '%s:5432:replication:replicator:%s\n' "$upstream" "$password" > /var/lib/postgresql/.pgpass
        chown postgres:postgres /var/lib/postgresql/.pgpass
        install -d -o postgres -g postgres -m 0700 "$PGDATA"
        exec gosu postgres bash /opt/replication.sh start-standby
    fi
    if [[ ${PGDR_NODE:-standby} == primary ]]; then
        [[ -f "$control/primary-rejoined" && -f "$PGDATA/standby.signal" ]] || die 'Rejoined primary must remain a standby.'
    elif [[ -f "$control/standby-promoted" ]]; then
        [[ -s "$PGDATA/PG_VERSION" ]] || die 'Promoted database is missing; refusing to initialize a replacement.'
        run_postgres
    fi
    if [[ -z $(ls -A "$PGDATA") ]]; then
        echo 'Seeding the empty standby volume from primary with pg_basebackup.'
        pg_basebackup --dbname="host=primary user=replicator application_name=standby passfile=/var/lib/postgresql/.pgpass connect_timeout=5 sslmode=verify-full sslrootcert=$tls/ca.crt" \
            --pgdata="$PGDATA" --wal-method=stream --write-recovery-conf \
            --slot=standby --checkpoint=fast --no-password
    elif [[ ! -s "$PGDATA/PG_VERSION" || ! -f "$PGDATA/standby.signal" ]]; then
        echo 'Standby target is nonempty but is not a seeded standby; refusing to overwrite or initialize it.' >&2
        exit 1
    fi
    configure_recovery_connection
    run_postgres
}

run_postgres() {
    exec postgres -D "$PGDATA" -c archive_mode=off -c hot_standby=on \
        -c wal_level=replica -c max_wal_senders=4 -c max_replication_slots=1 \
        -c max_slot_wal_keep_size=256MB -c wal_keep_size=64MB "${tls_options[@]}"
}

rewind_primary() {
    [[ ${PGDR_NODE:-} == primary && -f "$control/primary-fenced" ]] || die 'Rewind requires the fenced original primary.'
    [[ -s "$PGDATA/PG_VERSION" ]] || die 'Original primary data is missing; refusing to initialize it.'
    local source=/var/lib/postgresql/rewind-source
    pg_rewind --target-pgdata="$PGDATA" --source-pgdata="$source" --no-ensure-shutdown --dry-run
    pg_rewind --target-pgdata="$PGDATA" --source-pgdata="$source" --no-ensure-shutdown
    configure_recovery_connection
    touch "$PGDATA/standby.signal"
}

if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    initialize_primary
    return
fi

case "${1:-}" in
    start-primary) shift; start_primary "$@" ;;
    start-standby) start_standby ;;
    topology) topology; exit ;;
    promotion-target) cat "$control/promotion-target"; exit ;;
    fence-primary)
        [[ ${PGDR_NODE:-} == primary ]] || die 'Only the original primary can be fenced.'
        printf '%s\n' "$2" > "$control/promotion-target"
        touch "$control/primary-fenced"
        exit
        ;;
    rewind-primary) rewind_primary; exit ;;
esac

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compose=(bash "$root/scripts/compose.sh" --replication)
sql() {
    local service=$1
    shift
    "${compose[@]}" exec -T --user postgres "$service" \
        psql -X -v ON_ERROR_STOP=1 -U postgres -d orders "$@"
}

container_running() {
    local container
    container=$("${compose[@]}" ps --all --quiet "$1")
    [[ -n "$container" && $(docker inspect "$container" --format '{{.State.Running}}') == true ]]
}

read_topology() {
    "${compose[@]}" run --rm --no-deps --entrypoint bash primary /opt/replication.sh topology
}

wait_for_replay() {
    local node=$1 target=$2 deadline=$((SECONDS + 60))
    [[ "$target" =~ ^[0-9A-F]+/[0-9A-F]+$ ]] || die 'Invalid WAL replay target.'
    until [[ $(sql "$node" -Atc "SELECT pg_last_wal_replay_lsn() >= '$target'::pg_lsn;") == t ]]; do
        (( SECONDS < deadline )) || die "Node $node did not replay $target within 60 seconds."
        sleep 1
    done
}

start_cluster() {
    export PGDR_REPLICATION_DIR=${PGDR_REPLICATION_DIR:-$root/.local/replication}
    PGDR_SECRET_FILE="$PGDR_REPLICATION_DIR/postgres_password" PGDR_REPOSITORY=local \
        bash "$root/scripts/setup.sh"
    bash "$root/scripts/setup.sh" replication
    bash "$root/scripts/setup.sh" replication-tls
    "${compose[@]}" build
    case "$(read_topology)" in
        initial) "${compose[@]}" up --no-build --detach --wait --wait-timeout 180 ;;
        promoted|fenced) "${compose[@]}" up --no-build --no-deps --detach --wait --wait-timeout 180 standby ;;
        rejoined)
            "${compose[@]}" up --no-build --no-deps --detach --wait --wait-timeout 180 standby
            "${compose[@]}" up --no-build --no-deps --detach --wait --wait-timeout 180 primary
            ;;
        *) die 'Could not read replication transition state; startup refused.' ;;
    esac
}

promote_standby() {
    local state target container
    state=$(read_topology)
    [[ "$state" != rejoined ]] || die 'This project has already switched roles; reverse switchover is not supported.'
    [[ $(sql standby -Atc 'SELECT pg_is_in_recovery();') == t ]] || die 'Standby is already promoted or unavailable.'
    [[ $(sql standby -Atc 'SELECT pg_is_wal_replay_paused();') == f ]] || die 'Standby WAL replay is paused; promotion refused.'
    if [[ "$state" == initial ]]; then
        [[ $(sql primary -Atc 'SELECT pg_is_in_recovery();') == f ]] || die 'A running original primary is required for controlled switchover.'
        target=$(sql primary -Atc 'SELECT pg_current_wal_flush_lsn();')
        wait_for_replay standby "$target"
        "${compose[@]}" exec -T --user postgres primary bash /opt/replication.sh fence-primary "$target"
    else
        target=$("${compose[@]}" run --rm --no-deps --entrypoint bash primary /opt/replication.sh promotion-target)
        wait_for_replay standby "$target"
    fi
    "${compose[@]}" stop primary
    container=$("${compose[@]}" ps --all --quiet primary)
    [[ -n "$container" && $(docker inspect "$container" --format '{{.State.Running}}') == false ]] || die 'Could not verify the old primary is stopped; promotion refused.'
    "${compose[@]}" exec -T --user postgres standby touch "$control/standby-promoted"
    [[ $(sql standby -Atc 'SELECT pg_promote(true, 60);') == t ]] || die 'Promotion did not complete.'
    [[ $(sql standby -Atc 'SELECT pg_is_in_recovery();') == f ]] || die 'Promoted node is still in recovery.'
    sql standby -c "SELECT pg_create_physical_replication_slot('primary', true)
        WHERE NOT EXISTS (SELECT FROM pg_replication_slots WHERE slot_name = 'primary'); CHECKPOINT;"
    echo "Switchover complete: service standby is writable; original primary is fenced. Replay target: $target."
}

rejoin_primary() {
    local source_volume
    [[ $(read_topology) == promoted ]] || die 'Rejoin requires a promoted standby and a fenced original primary.'
    if container_running primary; then die 'Original primary is running; rejoin refused.'; fi
    [[ $(sql standby -Atc 'SELECT pg_is_in_recovery();') == f ]] || die 'New primary must be running and out of recovery.'
    sql standby -c "SELECT pg_create_physical_replication_slot('primary', true)
        WHERE NOT EXISTS (SELECT FROM pg_replication_slots WHERE slot_name = 'primary'); CHECKPOINT;"
    source_volume="${PGDR_REPLICATION_PROJECT:-postgres-dr-replication}_standby_data"
    "${compose[@]}" stop standby
    if ! "${compose[@]}" run --rm --no-deps --user postgres \
        --volume "$source_volume:/var/lib/postgresql/rewind-source:ro" \
        --entrypoint bash primary /opt/replication.sh rewind-primary; then
        "${compose[@]}" up --no-build --no-deps --detach --wait --wait-timeout 120 standby
        die 'Rewind failed; old primary remains fenced. Inspect its data before retrying; no automatic reseed is performed.'
    fi
    "${compose[@]}" up --no-build --no-deps --detach --wait --wait-timeout 120 standby
    "${compose[@]}" exec -T --user postgres standby touch "$control/primary-rejoined"
    "${compose[@]}" up --no-build --no-deps --detach --wait --wait-timeout 120 primary
    [[ $(sql primary -Atc 'SELECT pg_is_in_recovery();') == t ]] || die 'Rejoined node is not in recovery.'
    wait_for_replay primary "$(sql standby -Atc 'SELECT pg_current_wal_flush_lsn();')"
    echo 'Rejoin complete: service standby is primary; service primary is its read-only replica.'
}

show_status() {
    local node recovering
    printf '\nContainers\n'
    "${compose[@]}" ps --all
    for node in primary standby; do
        if ! container_running "$node"; then
            printf '\nService: %s | STOPPED\n' "$node"
            continue
        fi
        recovering=$(sql "$node" -Atc 'SELECT pg_is_in_recovery();')
        if [[ "$recovering" == t ]]; then
            printf '\nService: %s | Role: STANDBY (read-only)\n' "$node"
            echo 'Recovery: WAL applied to this database'
            sql "$node" -P null=unknown -c 'SELECT
                pg_is_in_recovery() AS "In recovery",
                pg_last_wal_replay_lsn() AS "Last replayed WAL (LSN)";'
            echo 'WAL receiver: connection from this standby to its upstream primary'
            sql "$node" -c 'SELECT status AS "Connection", slot_name AS "Slot",
                current_setting('\''primary_conninfo'\'') ~ '\''sslmode=verify-full'\'' AS "Verify server identity"
                FROM pg_stat_wal_receiver;'
        else
            printf '\nService: %s | Role: PRIMARY (read/write)\n' "$node"
            echo 'WAL sender: standbys receiving changes from this primary'
            sql "$node" -P null=unknown -c 'SELECT
                r.application_name AS "Standby", r.state AS "Connection", r.sync_state AS "Mode",
                pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS "Replay lag (bytes)"
                , s.ssl AS "TLS", s.version AS "Protocol", s.cipher AS "Cipher"
                FROM pg_stat_replication AS r LEFT JOIN pg_stat_ssl AS s USING (pid);'
            echo 'Replication slots: WAL kept for replicas, including disconnected ones'
            sql "$node" -P null=unknown -c 'SELECT slot_name AS "Slot", active AS "In use",
                wal_status AS "WAL retention",
                pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS "Retained WAL (bytes)"
                FROM pg_replication_slots;'
        fi
    done
    printf '\nLegend: t = yes; f = no; streaming = connected; async = commits do not wait for standby replay.\n'
    echo 'Replay lag uses the last position reported by the standby; unknown = no value is available.'
    echo 'No rows in a WAL sender/receiver table = no replication connection was observed.'
    echo 'TLS = encrypted connection; Verify server identity = receiver configured to verify its CA and hostname.'
}

open_sql() {
    local requested=$1 expected=f node
    shift
    local matches=()
    local tty_flags=()
    if [[ ! -t 0 || ! -t 1 ]]; then tty_flags=(-T); fi
    if [[ "$requested" == standby ]]; then expected=t; fi
    for node in primary standby; do
        if container_running "$node" && [[ $(sql "$node" -Atc 'SELECT pg_is_in_recovery();') == "$expected" ]]; then matches+=("$node"); fi
    done
    [[ ${#matches[@]} == 1 ]] || die "Expected exactly one running $requested; found ${#matches[@]}. Run make replication-status."
    "${compose[@]}" exec "${tty_flags[@]}" --user postgres "${matches[0]}" \
        psql -X -v ON_ERROR_STOP=1 -U postgres -d orders "$@"
}

# Serialize topology changes in this checkout. SQL clients must be stopped by the operator.
case "${1:-}" in
    up|promote|rejoin)
        project=${PGDR_REPLICATION_PROJECT:-postgres-dr-replication}
        [[ "$project" =~ ^postgres-dr-replication($|-[a-z0-9-]+$) ]] || die 'Invalid replication project.'
        mkdir -p "$root/.local/replication-locks"
        exec 9>"$root/.local/replication-locks/$project.lock"
        flock -n 9 || die 'Another replication topology command is running.'
        ;;
esac

case "${1:-}" in
    up)
        start_cluster
        ;;
    status)
        show_status
        ;;
    promote) promote_standby ;;
    rejoin) rejoin_primary ;;
    primary-psql) shift; open_sql primary "$@" ;;
    standby-psql) shift; open_sql standby "$@" ;;
    *) echo 'Usage: replication.sh up|status|promote|rejoin|primary-psql|standby-psql' >&2; exit 2 ;;
esac
