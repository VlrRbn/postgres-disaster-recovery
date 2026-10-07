#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
PGDR_PROJECT="postgres-dr-ui-test-$(date +%s)-$$"
export PGDR_PROJECT
export PGDR_SECRET_FILE="$work/postgres_password"
export PGDR_PGADMIN_SECRET_FILE="$work/pgadmin_password"
export PGADMIN_PORT=0
compose=(bash "$root/scripts/compose.sh")

cleanup() {
    local result=$?
    trap - EXIT
    if (( result != 0 )); then
        "${compose[@]}" --profile tools logs --no-color >&2 || true
    fi
    if "${compose[@]}" --profile tools down --volumes --remove-orphans; then
        rm -rf -- "$work"
    else
        echo "Cleanup failed for $PGDR_PROJECT; secrets retained at $work." >&2
        result=1
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

step() {
    printf '\n[%s/4] %s\n' "$1" "$2"
}

prepare_services() {
    step 1 "Start the primary and opt-in pgAdmin with private passwords"
    make -C "$root" up
    [[ -z $("${compose[@]}" ps --all --quiet pgadmin) ]]
    make -C "$root" pgadmin-up
    [[ $(stat -c %a "$PGDR_PGADMIN_SECRET_FILE") == 600 ]]
    sha256sum "$PGDR_PGADMIN_SECRET_FILE" >"$work/secret.sha256"
}

verify_access_and_isolation() {
    step 2 "Check loopback access, browser login, and SQL authentication"
    pgadmin_id=$("${compose[@]}" ps --quiet pgadmin)
    docker inspect "$pgadmin_id" >"$work/container.json"
    python3 - "$work/container.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    container = json.load(source)[0]
ports = container['NetworkSettings']['Ports']['5050/tcp']
assert len(ports) == 1 and ports[0]['HostIp'] == '127.0.0.1', ports
assert all(m['Destination'] not in ('/var/lib/postgresql/data', '/var/lib/pgbackrest')
           for m in container['Mounts'])
PY
    [[ $("${compose[@]}" port pgadmin 5050) == 127.0.0.1:* ]]
    postgres_id=$("${compose[@]}" ps --quiet postgres)
    [[ $(docker inspect --format '{{len .HostConfig.PortBindings}}' "$postgres_id") == 0 ]]
    [[ $(docker inspect --format '{{len .NetworkSettings.Networks}}' "$postgres_id") == 1 ]]
    [[ $(docker network inspect --format '{{.Internal}}' "${PGDR_PROJECT}_database") == true ]]
    endpoint=$("${compose[@]}" port pgadmin 5050)

    # Exercise browser login with cookies and CSRF, without logging either password.
    python3 - "$endpoint" "$PGDR_PGADMIN_SECRET_FILE" <<'PY'
from http.cookiejar import CookieJar
from pathlib import Path
import json
import re
import sys
from urllib.parse import urlencode
from urllib.request import build_opener, HTTPCookieProcessor

base = 'http://' + sys.argv[1]
client = build_opener(HTTPCookieProcessor(CookieJar()))
page = client.open(base + '/login', timeout=10)
# pgAdmin 9.18 renders its form in React; use the server-supplied page props.
html = page.read().decode()
match = re.search(r"window.renderSecurityPage\('login_user',\s*", html)
assert match, 'Login page did not supply its form configuration'
props, _ = json.JSONDecoder().raw_decode(html[match.end():])
body = urlencode({'email': 'admin@example.com',
                  'password': Path(sys.argv[2]).read_text().strip(),
                  'csrf_token': props['csrfToken']}).encode()
response = client.open(base + props['loginUrl'], data=body, timeout=20)
assert '/browser/' in response.url, 'pgAdmin login failed'
print('PASS: pgAdmin browser login with generated password.')
PY

    # Verify TCP authentication from the UI container against the primary database.
    "${compose[@]}" exec -T --user 5050 pgadmin /venv/bin/python3 -c '
import psycopg
import sys
with psycopg.connect(host="postgres", dbname="orders", user="postgres",
                     password=sys.stdin.read().strip(), connect_timeout=5) as conn:
    assert conn.execute("SELECT count(*) FROM orders").fetchone() == (0,)
print("PASS: authenticated SQL connection from pgAdmin to orders.")
' <"$PGDR_SECRET_FILE"
}

verify_recreation() {
    step 3 "Recreate pgAdmin and verify password and server persistence"
    make -C "$root" pgadmin-down
    [[ -n $("${compose[@]}" ps --status running --quiet postgres) ]]
    make -C "$root" pgadmin-up
    sha256sum --check --status "$work/secret.sha256"
    "${compose[@]}" exec -T --user 5050 pgadmin /venv/bin/python3 -c '
import sqlite3
from pathlib import Path
with sqlite3.connect("file:/var/lib/pgadmin/pgadmin4.db?mode=ro", uri=True) as conn:
    assert conn.execute("SELECT host, port, maintenance_db, username FROM server").fetchall() == [
        ("postgres", 5432, "orders", "postgres")]
uid = next(line for line in Path("/proc/1/status").read_text().splitlines() if line.startswith("Uid:"))
assert uid.split()[1:] == ["5050"] * 4, uid
'
}

verify_shutdown() {
    step 4 "Stop the lab and confirm pgAdmin data remains"
    make -C "$root" down
    [[ -z $("${compose[@]}" --profile tools ps --all --quiet) ]]
    docker volume inspect "${PGDR_PROJECT}_pgadmin_data" >/dev/null
    echo 'PASS: UI is opt-in and loopback-only; credentials and server registration survive recreation; make down retains UI data.'
}

# Run one complete disposable acceptance scenario.
prepare_services
verify_access_and_isolation
verify_recreation
verify_shutdown
