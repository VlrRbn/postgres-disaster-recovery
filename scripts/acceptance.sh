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

"${compose[@]}" up --detach --wait --wait-timeout 120
sql -Atc 'SELECT version();'
[[ $(sql -Atc 'SHOW data_checksums;') == on ]]
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
before_id=$("${compose[@]}" ps -q postgres)
"${compose[@]}" up --detach --force-recreate --wait --wait-timeout 120 postgres
after_id=$("${compose[@]}" ps -q postgres)
[[ -n "$before_id" && -n "$after_id" && "$before_id" != "$after_id" ]]
sql -c "$snapshot" >"$work/after.csv"
cmp "$work/before.csv" "$work/after.csv"
sql -c "INSERT INTO orders (reference, amount_cents) VALUES ('after-recreate', 2500);"
[[ $(sql -Atc 'SELECT count(*) FROM orders;') == 21 ]]
echo 'PASS: 20 complete records survived container recreation; new writes succeed; amount constraint and data checksums verified.'
