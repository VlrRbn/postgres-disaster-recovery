#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
PGDR_PROJECT="postgres-dr-test-$(date +%s)-$$"
export PGDR_PROJECT
export PGDR_SECRET_FILE="$work/postgres_password"
compose=(bash "$root/scripts/compose.sh")

cleanup() {
    local result=$?
    trap - EXIT
    if (( result != 0 )); then
        "${compose[@]}" logs --no-color >&2 || true
    fi
    if "${compose[@]}" down --volumes --remove-orphans; then
        rm -rf -- "$work"
    else
        echo "Cleanup failed for $PGDR_PROJECT; secret retained at $PGDR_SECRET_FILE." >&2
        result=1
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

python3 - "$PGDR_SECRET_FILE" <<'PY'
import os
import secrets
import sys
with os.fdopen(os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as out:
    out.write(secrets.token_hex(32) + "\n")
PY

sql() {
    "${compose[@]}" exec -T --user postgres postgres \
        psql -X -v ON_ERROR_STOP=1 -U postgres -d orders "$@"
}

pgbackrest() {
    "${compose[@]}" exec -T --user postgres postgres pgbackrest --stanza=orders "$@"
}

backup_label() {
    pgbackrest --log-level-console=off --output=json info >"$work/backup-info.json"
    python3 - "$work/backup-info.json" <<'JSON'
import json
import sys

with open(sys.argv[1]) as source:
    info = json.load(source)
assert len(info) == 1 and info[0]["name"] == "orders", info
stanza = info[0]
assert stanza["status"]["code"] == 0, stanza
assert len(stanza["backup"]) == 1, stanza
backup = stanza["backup"][0]
assert backup["type"] == "full" and backup["error"] is False, backup
assert backup["archive"]["start"] and backup["archive"]["stop"], backup
assert backup["info"]["size"] > 0, backup
print(backup["label"])
JSON
}

"${compose[@]}" up --build --detach --wait --wait-timeout 120
sql -Atc 'SELECT version();'
pgbackrest_version=$("${compose[@]}" exec -T --user postgres postgres pgbackrest version)
[[ "$pgbackrest_version" == 'pgBackRest 2.59.1' ]]
printf '%s\n' "$pgbackrest_version"
[[ $(sql -Atc 'SHOW server_version_num;') == 170011 ]]
[[ $(sql -Atc 'SHOW data_checksums;') == on ]]
[[ $(sql -Atc 'SHOW archive_mode;') == on ]]
[[ $(sql -Atc 'SHOW wal_level;') == replica ]]

# A fresh repository must fail with missing metadata, not claim backup readiness.
check_status=0
bash "$root/scripts/backup.sh" check >"$work/uninitialized.log" 2>&1 || check_status=$?
if [[ "$check_status" != 55 ]] || ! grep -q 'archive.info' "$work/uninitialized.log"; then
    cat "$work/uninitialized.log" >&2
    echo "Expected missing repository metadata (55); got $check_status." >&2
    exit 1
fi
bash "$root/scripts/backup.sh" init
empty_status=0
bash "$root/scripts/backup.sh" verify >"$work/empty.log" 2>&1 || empty_status=$?
if [[ "$empty_status" != 1 ]] || ! grep -q 'No healthy completed backup' "$work/empty.log"; then
    cat "$work/empty.log" >&2
    echo 'Expected verification to reject a repository with no completed backups.' >&2
    exit 1
fi
# Repeat the public initialization path to verify existing stanza reuse.
bash "$root/scripts/backup.sh" init
sql -c "INSERT INTO orders (reference, amount_cents)
        SELECT 'acceptance-' || n, n * 100 FROM generate_series(1, 20) AS n;"
[[ $(sql -Atc 'SELECT count(*) FROM orders;') == 20 ]]

# Exercise the schema constraint and require the expected SQLSTATE.
if sql --set=VERBOSITY=verbose -c "INSERT INTO orders (reference, amount_cents) VALUES ('invalid', -1);" >"$work/constraint.log" 2>&1; then
    echo 'Negative order amount was unexpectedly accepted.' >&2
    exit 1
fi
grep -q '23514' "$work/constraint.log"

snapshot='COPY (SELECT id, reference, amount_cents, created_at FROM orders ORDER BY id) TO STDOUT WITH CSV;'
sql -c "$snapshot" >"$work/before.csv"
bash "$root/scripts/backup.sh" full
before_backup=$(backup_label)
printf 'Verified full backup: %s\n' "$before_backup"

before_id=$("${compose[@]}" ps -q postgres)
"${compose[@]}" up --no-build --pull never --detach --force-recreate --wait --wait-timeout 120 postgres
after_id=$("${compose[@]}" ps -q postgres)
[[ -n "$before_id" && -n "$after_id" && "$before_id" != "$after_id" ]]
sql -c "$snapshot" >"$work/after.csv"
cmp "$work/before.csv" "$work/after.csv"
bash "$root/scripts/backup.sh" check
[[ $(backup_label) == "$before_backup" ]]
bash "$root/scripts/backup.sh" verify
sql -c "INSERT INTO orders (reference, amount_cents) VALUES ('after-recreate', 2500);"
[[ $(sql -Atc 'SELECT count(*) FROM orders;') == 21 ]]
# Damage only a file inside this script's disposable backup repository.
# Variables in the command expand inside the container.
# shellcheck disable=SC2016
"${compose[@]}" exec -T --user postgres postgres sh -ec '
    target="/var/lib/pgbackrest/backup/orders/$1/pg_data/PG_VERSION.gz"
    test -f "$target"
    cp "$target" /tmp/pgdr-original-PG_VERSION.gz
    printf corrupt >"$target"
' sh "$before_backup"
verify_status=0
bash "$root/scripts/backup.sh" verify >"$work/corrupt.log" 2>&1 || verify_status=$?
if [[ "$verify_status" != 1 ]] || ! grep -Fxq 'status: error' "$work/corrupt.log"; then
    cat "$work/corrupt.log" >&2
    echo "Expected corrupt backup verification to fail (1); got $verify_status." >&2
    exit 1
fi
# Variables in the command expand inside the container.
# shellcheck disable=SC2016
"${compose[@]}" exec -T --user postgres postgres sh -ec '
    cp /tmp/pgdr-original-PG_VERSION.gz "/var/lib/pgbackrest/backup/orders/$1/pg_data/PG_VERSION.gz"
    rm /tmp/pgdr-original-PG_VERSION.gz
' sh "$before_backup"
bash "$root/scripts/backup.sh" verify

echo 'PASS: empty and corrupt backups rejected; repaired test copy passes verification.'
echo 'PASS: PostgreSQL 17.11 and pgBackRest 2.59.1 verified as postgres.'
echo 'PASS: 20 complete records survived container recreation; new writes succeed; amount constraint and data checksums verified.'
echo 'PASS: uninitialized repository rejected; WAL archiving and full backup verified; backup retained after container recreation.'
