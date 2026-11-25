#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compose=(bash "$root/scripts/compose.sh" --patroni)

start_node() {
    local name
    [[ ${PGDR_PATRONI_NODE:-} == pg1 || ${PGDR_PATRONI_NODE:-} == pg2 ]] || { echo 'Invalid Patroni node.' >&2; exit 2; }
    install -d -o postgres -g postgres -m 0700 /var/lib/postgresql/patroni /var/lib/postgresql/patroni/tls /var/lib/postgresql/data
    for name in ca.crt server.crt server.key etcd-client.crt etcd-client.key; do
        install -o postgres -g postgres -m 0600 "/run/secrets/$name" "/var/lib/postgresql/patroni/tls/$name"
    done
    python3 /opt/patroni_config.py write
    chown postgres:postgres /var/lib/postgresql/patroni/patroni.json
    exec gosu postgres patroni /var/lib/postgresql/patroni/patroni.json
}

running() {
    local container
    container=$("${compose[@]}" ps --all --quiet "$1")
    [[ -n "$container" && $(docker inspect "$container" --format '{{.State.Running}}') == true ]]
}

find_node() {
    local requested=$1 node result
    local matches=()
    for node in pg1 pg2; do
        if running "$node"; then
            result=0
            "${compose[@]}" exec -T "$node" python3 /opt/patroni_config.py probe "$requested" || result=$?
            case "$result" in
                0) matches+=("$node") ;;
                1) ;;
                *) echo "Could not verify $node role; SQL connection refused." >&2; exit 1 ;;
            esac
        fi
    done
    [[ ${#matches[@]} == 1 ]] || { echo "Expected one $requested; found ${#matches[@]}. Run make patroni-status." >&2; exit 1; }
    printf '%s\n' "${matches[0]}"
}

open_sql() {
    local requested=$1 node
    shift
    local tty_flags=()
    if [[ ! -t 0 || ! -t 1 ]]; then tty_flags=(-T); fi
    node=$(find_node "$requested")
    "${compose[@]}" exec "${tty_flags[@]}" --user postgres "$node" psql -X -v ON_ERROR_STOP=1 -U postgres -d orders "$@"
}

endpoint_client() (
    umask 077
    local password passfile
    password=$(cat /run/secrets/postgres_password)
    password=${password//\\/\\\\}
    password=${password//:/\\:}
    passfile=$(mktemp)
    trap 'rm -f -- "$passfile"' EXIT
    printf 'haproxy:5432:orders:postgres:%s\n' "$password" > "$passfile"
    unset password
    PSQL_HISTORY=/dev/null PGPASSFILE="$passfile" PGSSLMODE=verify-full PGSSLROOTCERT=/run/secrets/ca.crt PGCONNECT_TIMEOUT=5 \
        psql -X -v ON_ERROR_STOP=1 -h haproxy -p 5432 -U postgres -d orders "$@"
)

wait_ready() {
    local node container status quorum primaries endpoint
    while true; do
        quorum=0
        primaries=0
        for node in etcd1 etcd2 etcd3; do
            container=$("${compose[@]}" ps --all --quiet "$node") || return 1
            if [[ -n "$container" ]]; then
                status=$(docker inspect "$container" --format '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{end}}') || return 1
                if [[ "$status" == 'true healthy' ]]; then quorum=$((quorum + 1)); fi
            fi
        done
        if (( quorum >= 2 )); then
            for node in pg1 pg2; do
                if "${compose[@]}" exec -T "$node" python3 /opt/patroni_config.py probe primary >/dev/null 2>&1; then
                    primaries=$((primaries + 1))
                fi
            done
            # /primary requires the leader lease. SQL also checks real TLS routing,
            # unlike HAProxy's configuration-only container healthcheck.
            if (( primaries == 1 )) && endpoint=$("${compose[@]}" run --rm --no-deps -T \
                --user "$(id -u):$(id -g)" client -Atq -c 'SELECT NOT pg_is_in_recovery()' 2>/dev/null) && [[ "$endpoint" == t ]]; then
                echo "Patroni is ready: etcd quorum $quorum/3, one primary, verified SQL through HAProxy."
                return 0
            fi
        fi
        sleep 1
    done
}

case "${1:-}" in
    start-node) start_node ;;
    endpoint-client) shift; endpoint_client "$@" ;;
    init)
        psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -c 'CREATE DATABASE orders;'
        psql -X -v ON_ERROR_STOP=1 -U postgres -d orders -f /opt/orders.sql
        pgbackrest --stanza=orders stanza-create
        ;;
    up)
        wait_seconds=${PGDR_PATRONI_WAIT_SECONDS:-180}
        if [[ ! "$wait_seconds" =~ ^[1-9][0-9]{0,2}$ ]] || (( wait_seconds > 300 )); then
            echo 'PGDR_PATRONI_WAIT_SECONDS must be an integer from 1 to 300.' >&2
            exit 2
        fi
        bash "$root/scripts/setup.sh" patroni
        "${compose[@]}" build pg1
        "${compose[@]}" up --no-build --detach
        if ! timeout "$wait_seconds" bash "$root/scripts/patroni.sh" wait-ready; then
            echo 'Patroni startup failed: require etcd quorum, exactly one leased primary and SQL through HAProxy.' >&2
            "${compose[@]}" ps --all >&2 || true
            "${compose[@]}" logs --no-color --tail 30 >&2 || true
            exit 1
        fi
        ;;
    wait-ready) wait_ready ;;
    status)
        "${compose[@]}" ps --all
        for node in pg1 pg2; do
            if running "$node"; then
                "${compose[@]}" exec -T --user postgres "$node" patronictl -c /var/lib/postgresql/patroni/patroni.json list
                exit
            fi
        done
        echo 'No running Patroni database node.' >&2
        exit 1
        ;;
    primary-psql) shift; open_sql primary "$@" ;;
    standby-psql) shift; open_sql replica "$@" ;;
    primary-node) find_node primary ;;
    backup-configure)
        node=$(find_node primary)
        "${compose[@]}" exec -T --user postgres "$node" python3 /opt/patroni_config.py archive-enable
        ;;
    endpoint-psql)
        shift
        tty_flags=()
        if [[ ! -t 0 || ! -t 1 ]]; then tty_flags=(-T); fi
        "${compose[@]}" run --rm --no-deps "${tty_flags[@]}" --user "$(id -u):$(id -g)" client "$@"
        ;;
    *) echo 'Usage: patroni.sh up|status|primary-psql|standby-psql|endpoint-psql|primary-node|backup-configure' >&2; exit 2 ;;
esac
