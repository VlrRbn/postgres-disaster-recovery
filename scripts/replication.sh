#!/usr/bin/env bash
set -euo pipefail

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
    printf '\nhost replication replicator samenet scram-sha-256\n' >> "$PGDATA/pg_hba.conf"
    rm /var/lib/postgresql/.replication_password
}

start_primary() {
    install -o postgres -g postgres -m 0600 /run/secrets/replication_password \
        /var/lib/postgresql/.replication_password
    exec /usr/local/bin/docker-entrypoint.sh "$@"
}

start_standby() {
    if [[ $(id -u) == 0 ]]; then
        local password
        password=$(cat /run/secrets/replication_password)
        password=${password//\\/\\\\}
        password=${password//:/\\:}
        umask 077
        printf 'primary:5432:replication:replicator:%s\n' "$password" > /var/lib/postgresql/.pgpass
        chown postgres:postgres /var/lib/postgresql/.pgpass
        install -d -o postgres -g postgres -m 0700 "$PGDATA"
        exec gosu postgres bash /opt/replication.sh start-standby
    fi
    if [[ -z $(ls -A "$PGDATA") ]]; then
        echo 'Seeding the empty standby volume from primary with pg_basebackup.'
        pg_basebackup --dbname='host=primary user=replicator application_name=standby passfile=/var/lib/postgresql/.pgpass connect_timeout=5 sslmode=disable' \
            --pgdata="$PGDATA" --wal-method=stream --write-recovery-conf \
            --slot=standby --checkpoint=fast --no-password
    elif [[ ! -s "$PGDATA/PG_VERSION" || ! -f "$PGDATA/standby.signal" ]]; then
        echo 'Standby target is nonempty but is not a seeded standby; refusing to overwrite or initialize it.' >&2
        exit 1
    fi
    exec postgres -D "$PGDATA" -c archive_mode=off -c hot_standby=on
}

if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    initialize_primary
    return
fi

case "${1:-}" in
    start-primary) shift; start_primary "$@" ;;
    start-standby) start_standby ;;
esac

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compose=(bash "$root/scripts/compose.sh" --replication)
sql() {
    local service=$1
    shift
    "${compose[@]}" exec -T --user postgres "$service" \
        psql -X -v ON_ERROR_STOP=1 -U postgres -d orders "$@"
}

case "${1:-}" in
    up)
        export PGDR_REPLICATION_DIR=${PGDR_REPLICATION_DIR:-$root/.local/replication}
        PGDR_SECRET_FILE="$PGDR_REPLICATION_DIR/postgres_password" PGDR_REPOSITORY=local \
            bash "$root/scripts/setup.sh"
        bash "$root/scripts/setup.sh" replication
        "${compose[@]}" up --build --detach --wait --wait-timeout 180
        ;;
    status)
        "${compose[@]}" ps
        sql primary -c "SELECT application_name, state, sync_state,
            pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes
            FROM pg_stat_replication;"
        sql primary -c "SELECT slot_name, active, wal_status,
            pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_wal_bytes
            FROM pg_replication_slots;"
        sql standby -c 'SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();'
        sql standby -c 'SELECT status, slot_name FROM pg_stat_wal_receiver;'
        ;;
    *) echo 'Usage: replication.sh up|status' >&2; exit 2 ;;
esac
