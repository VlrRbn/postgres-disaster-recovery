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
    [[ ! -e "$control/reseed-primary" ]] || die 'Standby reseed is incomplete; repeat make replication-reseed with RESEED_NODE=primary.'
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

prepare_standby() {
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
}

start_standby() {
    [[ ! -e "$control/reseed-${PGDR_NODE:-standby}" ]] || die 'Standby reseed is incomplete; repeat make replication-reseed with the same RESEED_NODE.'
    if [[ $(id -u) == 0 ]]; then
        prepare_standby
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

validate_reseed_target() {
    local expected=$1 identifier
    [[ "$expected" =~ ^[0-9]{19,20}$ && "$PGDATA" == /var/lib/postgresql/data && ! -L "$PGDATA" ]] || die 'Invalid reseed target or system identifier.'
    case "$(topology):${PGDR_NODE:-}" in
        initial:standby|rejoined:primary) ;;
        *) die 'Reseed requires the current standby in a stable topology.' ;;
    esac
    [[ ! -L "$PGDATA/.pgdr-reseed" ]] || die 'Reseed staging path must not be a symbolic link.'
    if [[ -f "$control/reseed-$PGDR_NODE" ]]; then
        [[ $(cat "$control/reseed-$PGDR_NODE") == "$expected" ]] || die 'Pending reseed belongs to another database system.'
    else
        [[ ! -e "$PGDATA/.pgdr-reseed" ]] || die 'Reseed staging exists without a pending marker; inspect it before proceeding.'
        [[ -s "$PGDATA/PG_VERSION" && -f "$PGDATA/standby.signal" ]] || die 'Reseed target must contain an existing standby.'
        identifier=$(LC_ALL=C pg_controldata "$PGDATA" | awk -F ': *' '/^Database system identifier:/ {print $2}')
        [[ "$identifier" == "$expected" ]] || die 'Standby and primary system identifiers differ; reseed refused.'
    fi
}

copy_standby() {
    local expected=$1 node=${PGDR_NODE:-} upstream=primary stage="$PGDATA/.pgdr-reseed"
    validate_reseed_target "$expected"
    if [[ $(id -u) == 0 ]]; then
        prepare_standby
        exec gosu postgres bash /opt/replication.sh copy-standby "$expected"
    fi
    if [[ "$node" == primary ]]; then upstream=standby; fi
    # The durable marker blocks startup throughout copying and file replacement.
    umask 077
    printf '%s\n' "$expected" > "$control/reseed-$node.tmp"
    mv -- "$control/reseed-$node.tmp" "$control/reseed-$node"
    rm -rf -- "$stage"
    mkdir -- "$stage"
    pg_basebackup --dbname="host=$upstream user=replicator application_name=$node passfile=/var/lib/postgresql/.pgpass connect_timeout=5 sslmode=verify-full sslrootcert=$tls/ca.crt" \
        --pgdata="$stage" --wal-method=stream --write-recovery-conf \
        --slot="$node" --checkpoint=fast --no-password
    pg_verifybackup "$stage"
    [[ $(LC_ALL=C pg_controldata "$stage" | awk -F ': *' '/^Database system identifier:/ {print $2}') == "$expected" ]] || die 'Copied database system identifier changed; original standby data preserved.'
    # Replace only this stopped standby's fixed PGDATA, keeping the staged copy.
    find "$PGDATA" -mindepth 1 -maxdepth 1 ! -name .pgdr-reseed -exec rm -rf -- {} +
    find "$stage" -mindepth 1 -maxdepth 1 -exec mv --target-directory="$PGDATA" -- {} +
    rmdir -- "$stage"
    configure_recovery_connection
    rm -- "$control/reseed-$node"
    echo "Verified base backup installed for service $node."
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
    reseed-check) validate_reseed_target "$2"; exit ;;
    reseed-pending) test -f "$control/reseed-$PGDR_NODE"; exit ;;
    reseed-mark)
        validate_reseed_target "$2"
        printf '%s\n' "$2" > "$control/reseed-$PGDR_NODE.tmp"
        mv -- "$control/reseed-$PGDR_NODE.tmp" "$control/reseed-$PGDR_NODE"
        exit
        ;;
    copy-standby) copy_standby "$2"; exit ;;
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

perform_switchover() {
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

reseed_standby() {
    local source replica identifier slot_status pending=false
    case "$(read_topology)" in
        initial) source=primary; replica=standby ;;
        rejoined) source=standby; replica=primary ;;
        *) die 'Reseed requires initial or rejoined topology; finish the current switchover first.' ;;
    esac
    [[ ${RESEED_NODE:-} == "$replica" ]] || die "Set RESEED_NODE=$replica to replace the current standby; primary service $source is preserved."
    [[ $(sql "$source" -Atc 'SELECT pg_is_in_recovery();') == f ]] || die 'Reseed requires the current primary to be reachable and writable.'
    [[ $(sql "$source" -Atc "SELECT count(*) FROM pg_tablespace WHERE spcname NOT IN ('pg_default', 'pg_global');") == 0 ]] || die 'Reseed does not support additional tablespaces.'
    identifier=$(sql "$source" -Atc 'SELECT system_identifier FROM pg_control_system();')
    "${compose[@]}" run --rm --no-deps --user postgres --entrypoint bash "$replica" \
        /opt/replication.sh reseed-check "$identifier"
    if "${compose[@]}" run --rm --no-deps --user postgres --entrypoint bash "$replica" /opt/replication.sh reseed-pending; then pending=true; fi
    slot_status=$(sql "$source" -Atc "SELECT slot_type || ':' || active || ':' || coalesce(wal_status, 'unknown')
        FROM pg_replication_slots WHERE slot_name = '$replica';")
    if "$pending"; then
        [[ -z "$slot_status" || "$slot_status" == physical:false:* ]] || die 'Pending reseed requires an inactive physical slot.'
    else
        [[ "$slot_status" == physical:false:lost ]] || die 'Reseed requires an inactive lost physical slot; healthy standbys are preserved.'
    fi
    if container_running "$replica"; then
        [[ $(sql "$replica" -Atc 'SELECT pg_is_in_recovery();') == t ]] || die 'Reseed target is writable; refusing to stop or replace it.'
    fi
    echo "Reseeding service $replica from writable service $source; the primary remains running."
    "${compose[@]}" stop "$replica"
    if container_running "$replica"; then die 'Standby did not stop; reseed refused.'; fi
    "${compose[@]}" run --rm --no-deps --user postgres --entrypoint bash "$replica" \
        /opt/replication.sh reseed-mark "$identifier"
    sql "$source" -c "SELECT pg_drop_replication_slot('$replica')
        WHERE EXISTS (SELECT FROM pg_replication_slots WHERE slot_name = '$replica');
        SELECT pg_create_physical_replication_slot('$replica', true);"
    "${compose[@]}" run --rm --no-deps --entrypoint bash "$replica" /opt/replication.sh copy-standby "$identifier"
    "${compose[@]}" up --no-build --no-deps --detach --wait --wait-timeout 120 "$replica"
    [[ $(sql "$replica" -Atc 'SELECT pg_is_in_recovery();') == t ]] || die 'Reseeded node is not in recovery.'
    wait_for_replay "$replica" "$(sql "$source" -Atc 'SELECT pg_current_wal_flush_lsn();')"
    echo "Reseed complete: service $replica is read-only and receiving WAL from service $source."
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

# Serialize topology changes here; switchover and rejoin require paused writers.
case "${1:-}" in
    up|switchover|rejoin|reseed)
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
    switchover) perform_switchover ;;
    rejoin) rejoin_primary ;;
    reseed) reseed_standby ;;
    primary-psql) shift; open_sql primary "$@" ;;
    standby-psql) shift; open_sql standby "$@" ;;
    *) echo 'Usage: replication.sh up|status|switchover|rejoin|reseed|primary-psql|standby-psql' >&2; exit 2 ;;
esac
