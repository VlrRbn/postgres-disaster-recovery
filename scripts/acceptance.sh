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
        "${compose[@]}" --profile restore logs --no-color >&2 || true
    fi
    if "${compose[@]}" --profile restore down --volumes --remove-orphans; then
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

# Finish archiving the later write, then restore without a running source database.
bash "$root/scripts/backup.sh" check
sql -c "$snapshot" >"$work/source-before-restore.csv"
"${compose[@]}" stop postgres
[[ -z $("${compose[@]}" ps --status running --quiet postgres) ]]

source_tool() {
    "${compose[@]}" run --rm --no-deps --entrypoint bash --user postgres postgres "$@"
}

repository_snapshot() {
    source_tool -euo pipefail -c 'find /var/lib/pgbackrest -type f -exec sha256sum {} + | sort'
}

restore_sql() {
    "${compose[@]}" exec -T --user postgres restore \
        psql -X -v ON_ERROR_STOP=1 -U postgres -d orders "$@"
}

repository_snapshot >"$work/repository-before.sha256"
"${compose[@]}" build restore

# A nonempty target must not be replaced, even when it is not a database yet.
"${compose[@]}" run --rm --no-deps --entrypoint sh restore -ec \
    'printf occupied >/var/lib/postgresql/data/sentinel'
restore_status=0
BACKUP_LABEL="$before_backup" bash "$root/scripts/restore.sh" restore >"$work/occupied.log" 2>&1 || restore_status=$?
if [[ "$restore_status" != 1 ]] || ! grep -q 'Restore target is not empty' "$work/occupied.log"; then
    cat "$work/occupied.log" >&2
    echo 'Expected an occupied restore target to be rejected.' >&2
    exit 1
fi
# shellcheck disable=SC2016
"${compose[@]}" run --rm --no-deps --entrypoint sh restore -ec \
    'test "$(cat /var/lib/postgresql/data/sentinel)" = occupied; rm /var/lib/postgresql/data/sentinel'

# Withhold one required WAL segment only in this disposable repository.
required_wal=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[0]["backup"][0]["archive"]["start"])' "$work/backup-info.json")
[[ "$required_wal" =~ ^[0-9A-F]{24}$ ]]
# shellcheck disable=SC2016
source_tool -euo pipefail -c '
    wal=$1
    files=(/var/lib/pgbackrest/archive/orders/17-1/"${wal:0:16}"/"$wal"-*.gz)
    (( ${#files[@]} == 1 ))
    test -f "${files[0]}"
    test ! -e /var/lib/pgbackrest/.pgdr-held-wal
    mv "${files[0]}" /var/lib/pgbackrest/.pgdr-held-wal
    printf "%s\n" "${files[0]}"
' bash "$required_wal" >"$work/required-wal-path"
restore_status=0
RESTORE_WAIT_SECONDS=15 BACKUP_LABEL="$before_backup" bash "$root/scripts/restore.sh" restore >"$work/missing-wal.log" 2>&1 || restore_status=$?
if [[ "$restore_status" == 0 ]] || ! grep -Fq "$required_wal" "$work/missing-wal.log"; then
    cat "$work/missing-wal.log" >&2
    echo 'Expected recovery to fail with the required WAL segment missing.' >&2
    exit 1
fi
"${compose[@]}" stop restore
"${compose[@]}" rm --force restore
# This volume belongs to the unique disposable project created above.
docker volume rm "${PGDR_PROJECT}_pgrestore"
# shellcheck disable=SC2016
source_tool -euo pipefail -c \
    'mv /var/lib/pgbackrest/.pgdr-held-wal "$1"' bash "$(cat "$work/required-wal-path")"

BACKUP_LABEL="$before_backup" bash "$root/scripts/restore.sh" restore
[[ -z $("${compose[@]}" ps --status running --quiet postgres) ]]
[[ $(restore_sql -Atc 'SELECT pg_is_in_recovery();') == f ]]
[[ $(restore_sql -Atc 'SHOW archive_mode;') == off ]]
restore_sql -c "$snapshot" >"$work/restored.csv"
cmp "$work/before.csv" "$work/restored.csv"
[[ $(restore_sql -Atc "SELECT count(*) FROM orders WHERE reference = 'after-recreate';") == 0 ]]

# Validate storage isolation in the running container, not only the YAML.
restore_id=$("${compose[@]}" ps --quiet restore)
docker inspect "$restore_id" >"$work/restore-container.json"
python3 - "$work/restore-container.json" "$PGDR_PROJECT" <<'MOUNTS'
import json
import sys
with open(sys.argv[1]) as source:
    container = json.load(source)[0]
mounts = {mount["Destination"]: mount for mount in container["Mounts"]}
assert mounts["/var/lib/postgresql/data"]["Name"] == sys.argv[2] + "_pgrestore"
assert mounts["/var/lib/pgbackrest"]["RW"] is False
assert all(mount.get("Name") != sys.argv[2] + "_pgdata" for mount in mounts.values())
assert container["HostConfig"]["NetworkMode"] == "none"
MOUNTS

restore_sql -c "INSERT INTO orders (reference, amount_cents) VALUES ('restored-write', 3500);"
[[ $(restore_sql -Atc 'SELECT count(*) FROM orders;') == 21 ]]
restore_sql -c "$snapshot" >"$work/restored-with-write.csv"
restore_status=0
BACKUP_LABEL="$before_backup" bash "$root/scripts/restore.sh" restore >"$work/running-target.log" 2>&1 || restore_status=$?
if [[ "$restore_status" != 1 ]] || ! grep -q 'Restore container already exists' "$work/running-target.log"; then
    cat "$work/running-target.log" >&2
    echo 'Expected an existing restore container to be rejected.' >&2
    exit 1
fi
"${compose[@]}" stop restore
bash "$root/scripts/restore.sh" start
restore_sql -c "$snapshot" >"$work/restored-after-restart.csv"
cmp "$work/restored-with-write.csv" "$work/restored-after-restart.csv"
repository_snapshot >"$work/repository-after.sha256"
cmp "$work/repository-before.sha256" "$work/repository-after.sha256"

# Resume the source and prove that restore-side writes did not change its records.
"${compose[@]}" up --no-build --pull never --detach --wait --wait-timeout 120 postgres
sql -c "$snapshot" >"$work/source-after-restore.csv"
cmp "$work/source-before-restore.csv" "$work/source-after-restore.csv"
echo 'PASS: missing WAL and occupied restore targets rejected.'
echo 'PASS: 20 records restored with source stopped; later source write excluded; restored writes survive restart.'
echo 'PASS: source records and repository contents unchanged by restore; restored repository mount is read-only.'

# PITR must replay post-backup commits but stop before the destructive transaction.
# Reuse only the disposable project's restore volume, never the interactive lab.
"${compose[@]}" stop restore
"${compose[@]}" rm --force restore
docker volume rm "${PGDR_PROJECT}_pgrestore"

for invalid_time in '' '2026-09-30 12:00:00' '2026-02-30 12:00:00+00:00'; do
    restore_status=0
    BACKUP_LABEL="$before_backup" RECOVERY_TIME="$invalid_time" \
        bash "$root/scripts/restore.sh" time >"$work/invalid-time.log" 2>&1 || restore_status=$?
    [[ "$restore_status" == 2 ]]
    grep -q 'Set RECOVERY_TIME' "$work/invalid-time.log"
done

sql -c "INSERT INTO orders (reference, amount_cents) VALUES ('pitr-before-delete', 4500);"
sql -c "$snapshot" >"$work/pitr-expected.csv"
recovery_time=$(sql -Atc "SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || '+00:00';")
printf 'PITR target: %s; backup: %s\n' "$recovery_time" "$before_backup"
sql -c "DELETE FROM orders;"
sql -c "INSERT INTO orders (reference, amount_cents) VALUES ('pitr-after-delete', 5500);"
[[ $(sql -Atc 'SELECT count(*) FROM orders;') == 1 ]]
sql -c "$snapshot" >"$work/pitr-damaged-source.csv"
bash "$root/scripts/backup.sh" check
"${compose[@]}" stop postgres
repository_snapshot >"$work/pitr-repository-before.sha256"

# An unreachable target must fail rather than promote at the end of available WAL.
future_time=$(date -u --date="$recovery_time +1 day" '+%Y-%m-%d %H:%M:%S+00:00')
restore_status=0
RESTORE_WAIT_SECONDS=15 BACKUP_LABEL="$before_backup" RECOVERY_TIME="$future_time" \
    bash "$root/scripts/restore.sh" time >"$work/unreachable-time.log" 2>&1 || restore_status=$?
if [[ "$restore_status" == 0 ]] || ! grep -q 'recovery ended before configured recovery target was reached' "$work/unreachable-time.log"; then
    cat "$work/unreachable-time.log" >&2
    echo 'Expected an unreachable recovery time to fail without promotion.' >&2
    exit 1
fi
"${compose[@]}" stop restore
"${compose[@]}" rm --force restore
docker volume rm "${PGDR_PROJECT}_pgrestore"

BACKUP_LABEL="$before_backup" RECOVERY_TIME="$recovery_time" bash "$root/scripts/restore.sh" time
[[ -z $("${compose[@]}" ps --status running --quiet postgres) ]]
[[ $(restore_sql -Atc 'SELECT pg_is_in_recovery();') == f ]]
[[ $(restore_sql -Atc 'SHOW archive_mode;') == off ]]
restore_sql -c "$snapshot" >"$work/pitr-restored.csv"
cmp "$work/pitr-expected.csv" "$work/pitr-restored.csv"
[[ $(restore_sql -Atc 'SELECT count(*) FROM orders;') == 22 ]]
[[ $(restore_sql -Atc "SELECT count(*) FROM orders WHERE reference = 'pitr-after-delete';") == 0 ]]
restore_sql -c "INSERT INTO orders (reference, amount_cents) VALUES ('pitr-restored-write', 6500);"
restore_sql -c "$snapshot" >"$work/pitr-with-write.csv"
"${compose[@]}" stop restore
bash "$root/scripts/restore.sh" start
restore_sql -c "$snapshot" >"$work/pitr-after-restart.csv"
cmp "$work/pitr-with-write.csv" "$work/pitr-after-restart.csv"
repository_snapshot >"$work/pitr-repository-after.sha256"
cmp "$work/pitr-repository-before.sha256" "$work/pitr-repository-after.sha256"
"${compose[@]}" up --no-build --pull never --detach --wait --wait-timeout 120 postgres
sql -c "$snapshot" >"$work/pitr-source-after.csv"
cmp "$work/pitr-damaged-source.csv" "$work/pitr-source-after.csv"
echo 'PASS: PITR restored 22 exact records before deletion; later transaction excluded; restored writes survive restart.'
echo 'PASS: invalid and unreachable recovery times rejected; source and repository unchanged by PITR.'

echo 'PASS: empty and corrupt backups rejected; repaired test copy passes verification.'
echo 'PASS: PostgreSQL 17.11 and pgBackRest 2.59.1 verified as postgres.'
echo 'PASS: 20 complete records survived container recreation; new writes succeed; amount constraint and data checksums verified.'
echo 'PASS: uninitialized repository rejected; WAL archiving and full backup verified; backup retained after container recreation.'
