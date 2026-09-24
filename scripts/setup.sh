#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$root/.local/postgres_password" <<'PY'
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
        sys.exit("Existing password file is invalid; inspect .local/postgres_password.")
    print("Existing local password preserved.")
else:
    with os.fdopen(fd, "w") as out:
        out.write(secrets.token_hex(32) + "\n")
    print("Local password generated in ignored .local/postgres_password.")
PY
