#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

schedule_units=(postgres-dr-backup.service postgres-dr-backup.timer
    postgres-dr-backup-health.service postgres-dr-backup-health.timer)

stop_schedule() {
    local unit_dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user unit
    local timers=()
    for unit in postgres-dr-backup.timer postgres-dr-backup-health.timer; do
        if [[ -e "$unit_dir/$unit" ]]; then timers+=("$unit"); fi
    done
    if (( ${#timers[@]} == 0 )); then
        echo 'No installed project timers; nothing to disable.'
        return
    fi
    systemctl --user disable --now "${timers[@]}"
    echo 'Timers disabled; any running job is allowed to finish.'
}

require_schedule_idle() {
    local unit_dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user unit state
    for unit in postgres-dr-backup.service postgres-dr-backup-health.service; do
        [[ -e "$unit_dir/$unit" ]] || continue
        state=$(systemctl --user show "$unit" --property=ActiveState --value) || {
            echo "Cannot read $unit state; operation refused." >&2
            exit 1
        }
        case "$state" in
            active|activating|reloading|deactivating)
                echo "$unit is still running; let it finish and repeat the command." >&2
                exit 1
                ;;
        esac
    done
}

install_schedule() {
    local config_home=${XDG_CONFIG_HOME:-$HOME/.config}
    local unit
    [[ "$config_home" == /* ]] || { echo 'XDG_CONFIG_HOME must be an absolute path.' >&2; exit 2; }
    mkdir -p "$config_home/systemd/user"
    python3 - "$root" "$config_home/postgres-dr/schedule.env" <<'PY'
import json
import os
from pathlib import Path
import sys

root, path = map(Path, sys.argv[1:])
if any(ord(char) < 32 for char in str(root)):
    sys.exit('Repository path must not contain control characters.')
path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
try:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
except FileExistsError:
    if not path.is_file() or not path.read_text().strip():
        sys.exit(f'Existing schedule config is invalid; inspect {path}.')
    print(f'Existing schedule config preserved: {path}')
else:
    settings = {
        'PGDR_ROOT': str(root),
        'PGDR_REPOSITORY': 'local',
        'PGDR_PROJECT': 'postgres-dr-local',
        'PGDR_SECRET_FILE': str(root / '.local/postgres_password'),
        'PGDR_S3_FIXTURE': '0',
        'PGDR_BACKUP_MAX_AGE_SECONDS': '93600',
        'PGDR_ARCHIVE_TIMEOUT_SECONDS': '10',
        'PGDR_SCHEDULE_LOCK_TIMEOUT_SECONDS': '300',
    }
    with os.fdopen(fd, 'w') as out:
        for key, value in settings.items():
            out.write(f'{key}={json.dumps(value, ensure_ascii=False)}\n')
    print(f'Private schedule config generated: {path}')
PY
    for unit in "${schedule_units[@]}"; do
        install -m 0644 "$root/systemd/user/$unit" "$config_home/systemd/user/$unit"
    done
    systemd-analyze --user verify "${schedule_units[@]/#/$config_home/systemd/user/}"
    systemctl --user daemon-reload
    echo 'User units installed. Review schedule.env, then run make schedule-start to enable the timers.'
}

remove_schedule() {
    local config_home=${XDG_CONFIG_HOME:-$HOME/.config} unit
    [[ "$config_home" == /* ]] || { echo 'XDG_CONFIG_HOME must be an absolute path.' >&2; exit 2; }
    require_schedule_idle
    for unit in "${schedule_units[@]}"; do
        rm -f -- "$config_home/systemd/user/$unit"
    done
    systemctl --user daemon-reload
    echo "User units removed; config retained at $config_home/postgres-dr/schedule.env."
}
select_secret_file() {
    case "$1" in
        postgres)
            if [[ ${PGDR_REPOSITORY:-local} == s3 ]]; then
                secret_file=${PGDR_SECRET_FILE:-${PGDR_S3_DIR:-$root/.local/s3}/postgres_password}
            else
                secret_file=${PGDR_SECRET_FILE:-$root/.local/postgres_password}
            fi
            ;;
        pgadmin) secret_file=${PGDR_PGADMIN_SECRET_FILE:-$root/.local/pgadmin_password} ;;
        replication) secret_file=${PGDR_REPLICATION_DIR:-$root/.local/replication}/replication_password ;;
        *) echo 'Usage: setup.sh [postgres|pgadmin|replication]' >&2; exit 2 ;;
    esac
}

create_or_preserve_secret() {
    python3 - "$secret_file" <<'PY'
import os
from pathlib import Path
import secrets
import sys

path = Path(sys.argv[1])
path.parent.mkdir(mode=0o700, exist_ok=True)
try:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
except FileExistsError:
    if not path.is_file() or not path.read_text().strip():
        sys.exit(f"Existing password file is invalid; inspect {path}.")
    print(f"Existing local password preserved: {path}")
else:
    with os.fdopen(fd, "w") as out:
        out.write(secrets.token_hex(32) + "\n")
    print(f"Local password generated: {path}")
PY
}

# Select the runtime's password file, then create it only when absent.
case "${1:-}" in
    schedule) install_schedule; exit ;;
    schedule-stop) stop_schedule; exit ;;
    schedule-idle) require_schedule_idle; exit ;;
    schedule-remove) remove_schedule; exit ;;
esac
select_secret_file "${1:-postgres}"
create_or_preserve_secret
