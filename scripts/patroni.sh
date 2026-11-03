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

open_sql() {
    local requested=$1 node result
    shift
    local matches=() tty_flags=()
    if [[ ! -t 0 || ! -t 1 ]]; then tty_flags=(-T); fi
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
    "${compose[@]}" exec "${tty_flags[@]}" --user postgres "${matches[0]}" psql -X -v ON_ERROR_STOP=1 -U postgres -d orders "$@"
}

case "${1:-}" in
    start-node) start_node ;;
    init)
        psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -c 'CREATE DATABASE orders;'
        psql -X -v ON_ERROR_STOP=1 -U postgres -d orders -f /opt/orders.sql
        ;;
    up)
        bash "$root/scripts/setup.sh" patroni
        "${compose[@]}" up --build --detach --wait --wait-timeout 180
        ;;
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
    *) echo 'Usage: patroni.sh up|status|primary-psql|standby-psql' >&2; exit 2 ;;
esac
