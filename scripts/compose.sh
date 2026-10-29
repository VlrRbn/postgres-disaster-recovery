#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

stop_all() {
    local listing container project processes
    local containers=()
    bash "$root/scripts/setup.sh" schedule-disable
    bash "$root/scripts/setup.sh" schedule-idle

    # Match both this checkout and our Compose project prefix, including custom projects.
    listing=$(docker ps --filter "label=com.docker.compose.project.working_dir=$root" \
        --format '{{.ID}} {{.Label "com.docker.compose.project"}}')
    while read -r container project; do
        if [[ -n "$container" && "$project" == postgres-dr-* ]]; then
            containers+=("$container")
        fi
    done <<< "$listing"
    if (( ${#containers[@]} == 0 )); then
        echo 'No running project containers in this checkout.'
        return
    fi
    # A manually launched backup may also be running outside the systemd services.
    for container in "${containers[@]}"; do
        # Docker needs the PID column to select this container's host processes.
        processes=$(docker top "$container" -eo pid,args)
        if grep -Eq 'pgbackrest.*( backup([[:space:]]|$)|\[backup(:|\]))' <<< "$processes"; then
            echo "Backup is running in container $container; let it finish and repeat make stop-all." >&2
            exit 1
        fi
    done
    docker stop --timeout 30 "${containers[@]}"
    echo 'Project containers stopped. Containers, networks, volumes, secrets and backups retained.'
}

if [[ ${1:-} == --stop-all ]]; then
    stop_all
    exit
fi
if [[ ${1:-} == --replication ]]; then
    shift
    project=${PGDR_REPLICATION_PROJECT:-postgres-dr-replication}
    if [[ ! "$project" =~ ^postgres-dr-replication($|-[a-z0-9-]+$) ]]; then
        echo 'Replication requires a postgres-dr-replication or postgres-dr-replication-* project.' >&2
        exit 2
    fi
    export PGDR_REPLICATION_DIR=${PGDR_REPLICATION_DIR:-$root/.local/replication}
    exec docker compose --project-name "$project" --project-directory "$root" \
        --file "$root/compose.replication.yaml" "$@"
fi
# Select the configuration and defaults for one isolated runtime.
case "${PGDR_REPOSITORY:-local}" in
    local)
        project=${PGDR_PROJECT:-postgres-dr-local}
        config="$root/compose.yaml"
        export PGDR_SECRET_FILE=${PGDR_SECRET_FILE:-$root/.local/postgres_password}
        ;;
    s3)
        project=${PGDR_PROJECT:-postgres-dr-s3}
        if [[ ! "$project" =~ ^postgres-dr-s3($|-[a-z0-9-]+$) ]]; then
            echo 'S3 mode requires PGDR_PROJECT=postgres-dr-s3 or a postgres-dr-s3-* project.' >&2
            exit 2
        fi
        config="$root/compose.s3.yaml"
        export PGDR_S3_DIR=${PGDR_S3_DIR:-$root/.local/s3}
        export PGDR_SECRET_FILE=${PGDR_SECRET_FILE:-$PGDR_S3_DIR/postgres_password}
        ;;
    *) echo 'PGDR_REPOSITORY must be local or s3.' >&2; exit 2 ;;
esac
# Validate the project before forwarding any operator command to Docker.
if [[ ! "$project" =~ ^postgres-dr-[a-z0-9-]+$ ]]; then
    echo 'PGDR_PROJECT must start with postgres-dr- and use lowercase letters, digits or hyphens.' >&2
    exit 1
fi
configs=(--file "$config")
# The disposable API acceptance uses the same operational commands with its fixture overlay.
if [[ ${PGDR_S3_FIXTURE:-0} == 1 ]]; then
    if [[ ${PGDR_REPOSITORY:-local} != s3 ]]; then
        echo 'The S3 API fixture requires PGDR_REPOSITORY=s3.' >&2
        exit 2
    fi
    configs+=(--file "$root/compose.s3-test.yaml")
fi
exec docker compose --project-name "$project" --project-directory "$root" "${configs[@]}" "$@"
