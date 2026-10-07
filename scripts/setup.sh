#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
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
        *) echo 'Usage: setup.sh [postgres|pgadmin]' >&2; exit 2 ;;
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
select_secret_file "${1:-postgres}"
create_or_preserve_secret
