#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

schedule_units=(postgres-dr-backup.service postgres-dr-backup.timer
    postgres-dr-backup-health.service postgres-dr-backup-health.timer)

validate_tls() {
    local tls=$1 profile=${2:-replication} name mode certificate_key private_key
    local names=(primary standby)
    if [[ "$profile" == patroni ]]; then names=(pg1 pg2 etcd1 etcd2 etcd3 patroni); fi
    for name in ca "${names[@]}"; do
        [[ -s "$tls/$name.crt" && -s "$tls/$name.key" &&
           ! -L "$tls/$name.crt" && ! -L "$tls/$name.key" && -O "$tls/$name.key" ]] || {
            echo "Incomplete or unsafe TLS files in $tls; inspect them before retrying." >&2
            return 1
        }
        mode=$(stat -c %a "$tls/$name.key")
        (( (8#$mode & 077) == 0 )) || { echo "Private TLS key must not be group/world-readable: $name.key" >&2; return 1; }
        certificate_key=$(openssl x509 -in "$tls/$name.crt" -pubkey -noout | openssl sha256)
        private_key=$(openssl pkey -in "$tls/$name.key" -passin pass: -pubout | openssl sha256)
        [[ "$certificate_key" == "$private_key" ]] || { echo "TLS key does not match $name.crt." >&2; return 1; }
    done
    openssl verify -check_ss_sig -CAfile "$tls/ca.crt" "$tls/ca.crt" > /dev/null
    for name in "${names[@]}"; do
        openssl verify -purpose sslserver -verify_hostname "$name" \
            -CAfile "$tls/ca.crt" "$tls/$name.crt" > /dev/null
        if [[ "$profile" == patroni ]]; then
            openssl verify -purpose sslclient -CAfile "$tls/ca.crt" "$tls/$name.crt" > /dev/null
        fi
    done
}

upgrade_patroni_endpoint_tls() (
    umask 077
    local tls=$1 work name
    local missing=()
    for name in pg1 pg2; do
        if ! openssl verify -verify_hostname haproxy -CAfile "$tls/ca.crt" "$tls/$name.crt" > /dev/null 2>&1; then
            missing+=("$name")
        fi
    done
    if (( ${#missing[@]} == 0 )); then return; fi
    work=$(mktemp -d "$tls/.endpoint-XXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    # Validate every replacement before changing certificates; preserve CA and keys.
    for name in "${missing[@]}"; do
        openssl req -new -key "$tls/$name.key" -subj "/CN=$name" \
            -out "$work/$name.csr" > /dev/null 2>&1
        printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1,DNS:haproxy\n' "$name" > "$work/extensions"
        openssl x509 -req -sha256 -days 90 -in "$work/$name.csr" \
            -CA "$tls/ca.crt" -CAkey "$tls/ca.key" -set_serial "0x$(openssl rand -hex 16)" \
            -extfile "$work/extensions" -out "$work/$name.crt" > /dev/null 2>&1
        openssl verify -purpose sslserver -verify_hostname "$name" \
            -CAfile "$tls/ca.crt" "$work/$name.crt" > /dev/null
        openssl verify -purpose sslserver -verify_hostname haproxy \
            -CAfile "$tls/ca.crt" "$work/$name.crt" > /dev/null
    done
    for name in "${missing[@]}"; do mv -- "$work/$name.crt" "$tls/$name.crt"; done
    echo 'Added the haproxy DNS identity to PostgreSQL certificates; existing CA and private keys preserved.'
)

setup_tls() (
    umask 077
    local profile=${1:-replication} directory=${PGDR_REPLICATION_DIR:-$root/.local/replication} tls work name extensions san
    local names=(primary standby)
    if [[ "$profile" == patroni ]]; then
        directory=${PGDR_PATRONI_DIR:-$root/.local/patroni}
        names=(pg1 pg2 etcd1 etcd2 etcd3 patroni)
    fi
    tls="$directory/tls"
    if [[ -e "$tls" || -L "$tls" ]]; then
        [[ -d "$tls" && ! -L "$tls" ]] || { echo 'TLS path must be a directory, not a symlink.' >&2; exit 1; }
        validate_tls "$tls" "$profile"
        if [[ "$profile" == patroni ]]; then upgrade_patroni_endpoint_tls "$tls"; fi
        echo "Existing valid $profile TLS material preserved: $tls"
        exit
    fi
    mkdir -p "$directory"
    work=$(mktemp -d "$directory/.tls-XXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 365 \
        -subj "/CN=postgres-dr-$profile-ca" \
        -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' \
        -keyout "$work/ca.key" -out "$work/ca.crt" > /dev/null 2>&1
    for name in "${names[@]}"; do
        openssl req -new -newkey rsa:2048 -nodes -sha256 -subj "/CN=$name" \
            -keyout "$work/$name.key" -out "$work/$name.csr" > /dev/null 2>&1
        extensions=serverAuth
        san="DNS:$name"
        if [[ "$profile" == patroni ]]; then
            extensions=serverAuth,clientAuth
            san+=',DNS:localhost,IP:127.0.0.1'
            if [[ "$name" == pg1 || "$name" == pg2 ]]; then san+=',DNS:haproxy'; fi
        fi
        printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=%s\nsubjectAltName=%s\n' "$extensions" "$san" > "$work/extensions"
        openssl x509 -req -sha256 -days 90 -in "$work/$name.csr" \
            -CA "$work/ca.crt" -CAkey "$work/ca.key" -set_serial "0x$(openssl rand -hex 16)" \
            -extfile "$work/extensions" -out "$work/$name.crt" > /dev/null 2>&1
        rm -- "$work/$name.csr"
    done
    rm -- "$work/extensions"
    validate_tls "$work" "$profile"
    mv -T -- "$work" "$tls"
    echo "Private $profile CA and 90-day node certificates generated: $tls"
)

disable_schedule() {
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
    echo 'User units installed. Review schedule.env, then run make schedule-enable to enable the timers.'
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
        *) echo 'Usage: setup.sh [postgres|pgadmin|replication|replication-tls]' >&2; exit 2 ;;
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
    replication-tls) setup_tls; exit ;;
    patroni)
        directory=${PGDR_PATRONI_DIR:-$root/.local/patroni}
        mkdir -p "$directory"
        for name in postgres replication patroni_api; do
            secret_file="$directory/${name}_password"
            create_or_preserve_secret
        done
        setup_tls patroni
        exit
        ;;
    schedule) install_schedule; exit ;;
    schedule-disable) disable_schedule; exit ;;
    schedule-idle) require_schedule_idle; exit ;;
    schedule-remove) remove_schedule; exit ;;
esac
select_secret_file "${1:-postgres}"
create_or_preserve_secret
