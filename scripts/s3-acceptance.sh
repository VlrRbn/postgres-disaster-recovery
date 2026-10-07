#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
export PGDR_REPOSITORY=s3
PGDR_PROJECT="postgres-dr-s3-test-$(date +%s)-$$"
export PGDR_PROJECT
export PGDR_S3_DIR="$work"
export PGDR_SECRET_FILE="$work/postgres_password"
restore_name="$PGDR_PROJECT-retention-restore"
restore_volume="${PGDR_PROJECT}_retention_restore"
compose=(docker compose --project-name "$PGDR_PROJECT" --project-directory "$root"
    --file "$root/compose.s3.yaml" --file "$root/compose.s3-test.yaml")

cleanup() {
    local result=$?
    trap - EXIT
    if (( result != 0 )); then
        "${compose[@]}" logs --no-color >&2 || true
        docker logs "$restore_name" >&2 || true
    fi
    local cleanup_failed=0
    if docker container inspect "$restore_name" >/dev/null 2>&1; then
        docker rm --force "$restore_name" || cleanup_failed=1
    fi
    "${compose[@]}" down --volumes --remove-orphans || cleanup_failed=1
    if docker volume inspect "$restore_volume" >/dev/null 2>&1; then
        docker volume rm "$restore_volume" || cleanup_failed=1
    fi
    if (( cleanup_failed == 0 )); then
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

sql() {
    "${compose[@]}" exec -T --user postgres postgres \
        psql -X -v ON_ERROR_STOP=1 -U postgres -d orders "$@"
}
restore_sql() {
    docker exec --user postgres "$restore_name" \
        psql -X -v ON_ERROR_STOP=1 -U postgres -d orders "$@"
}

pgbackrest() {
    "${compose[@]}" exec -T --user postgres postgres pgbackrest --stanza=orders "$@"
}

backup() {
    bash "$root/scripts/backup.sh" "$@"
}

backup_info() {
    pgbackrest --log-level-console=off --output=json info
}

step() {
    printf '\n[%s/5] %s\n' "$1" "$2"
}

wait_for_recovery() {
    local attempt
    for (( attempt=0; attempt<60; attempt++ )); do
        if [[ $(restore_sql -Atc 'SELECT NOT pg_is_in_recovery();' 2>/dev/null || true) == t ]]; then
            return 0
        fi
        sleep 1
    done
    echo 'Recovered PostgreSQL did not leave recovery within 60 attempts.' >&2
    return 1
}

prepare_fixture() {
    step 1 "Prepare a versioned S3 fixture and trusted TLS"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=s3 \
        -addext subjectAltName=DNS:s3 -keyout "$work/server.key" -out "$work/server.crt" >/dev/null 2>&1
    chmod 0600 "$work/server.key"
    chmod 0644 "$work/server.crt"
    python3 - "$root" "$work/pgbackrest.conf" <<'PY'
import configparser
import io
import sys
sys.path.insert(0, sys.argv[1])
from scripts.setup_s3 import build_config, write_private
settings = {'bucket': 'postgres-dr-fixture', 'region': 'eu-west-1',
            'prefix': 'postgres-dr/orders', 'profile': 'synthetic-test'}
config = configparser.ConfigParser(interpolation=None)
config.read_string(build_config(settings, {'AccessKeyId': 'testing', 'SecretAccessKey': 'testing'}))
# Trust only the generated fixture certificate, with hostname verification enabled.
config['global'].update({'repo1-s3-endpoint': 's3', 'repo1-storage-port': '5000',
                         'repo1-storage-ca-file': '/opt/s3-ca.crt'})
output = io.StringIO()
config.write(output, space_around_delimiters=False)
write_private(sys.argv[2], output.getvalue())
PY
    bash "$root/scripts/setup.sh"
    "${compose[@]}" up --detach --wait --wait-timeout 120 s3
    "${compose[@]}" exec -T moto python - <<'PY'
import boto3
client = boto3.client('s3', endpoint_url='http://127.0.0.1:5000', region_name='eu-west-1',
                      aws_access_key_id='testing', aws_secret_access_key='testing')
client.create_bucket(Bucket='postgres-dr-fixture', CreateBucketConfiguration={'LocationConstraint': 'eu-west-1'})
client.put_bucket_versioning(Bucket='postgres-dr-fixture', VersioningConfiguration={'Status': 'Enabled'})
PY
    "${compose[@]}" up --build --detach --wait --wait-timeout 120 postgres
    backup init
}

verify_backup_and_recreation() {
    step 2 "Create a backup and verify container recreation"
    sql -c "INSERT INTO orders (reference, amount_cents) VALUES ('s3-preserved', 100);"
    backup full
    backup_info >"$work/info-before.json"
    "${compose[@]}" exec -T --user postgres postgres stat -c '%a:%U:%G' /etc/pgbackrest/pgbackrest.conf |
        grep -Fx '600:postgres:postgres'

    "${compose[@]}" up --no-build --force-recreate --detach --wait --wait-timeout 120 postgres
    backup check
    backup verify
    backup_info >"$work/info-after.json"
    sql -Atc "SELECT count(*) FROM orders WHERE reference = 's3-preserved' AND amount_cents = 100;" |
        grep -Fx 1
    if pgbackrest --repo1-s3-bucket=postgres-dr-missing --io-timeout=2 --archive-timeout=2 check >"$work/missing.log" 2>&1; then
        echo 'Missing S3 bucket unexpectedly passed its archive check.' >&2
        exit 1
    fi
    grep -Eq 'NoSuchBucket|404|archive.info' "$work/missing.log"
    "${compose[@]}" exec -T --user postgres postgres test ! -e /var/lib/pgbackrest/backup/orders
    primary_id=$("${compose[@]}" ps --quiet postgres)
    docker inspect "$primary_id" >"$work/container.json"
}

verify_retention() {
    step 3 "Create three full backups and retain the newest two"
    # Capture a post-backup target so successful recovery must replay retained WAL.
    sql -c "INSERT INTO orders (reference, amount_cents) VALUES ('s3-retention-second', 200);"
    backup full
    backup_info >"$work/info-second.json"
    retained_label=$(python3 - "$work/info-second.json" <<'PY_LABEL'
import json
import sys

with open(sys.argv[1]) as source:
    backups = json.load(source)[0]['backup']
latest = max(backups, key=lambda backup: backup['timestamp']['stop'])
print(latest['label'])
PY_LABEL
    )
    sql -c "INSERT INTO orders (reference, amount_cents) VALUES ('s3-retention-wal', 300);"
    sql -c 'COPY (SELECT id, reference, amount_cents, created_at FROM orders ORDER BY id) TO STDOUT WITH CSV;' >"$work/retention-expected.csv"
    recovery_time=$(sql -Atc "SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || '+00:00';")
    backup check
    sql -c "INSERT INTO orders (reference, amount_cents) VALUES ('s3-retention-third', 400);"
    backup full
    backup_info >"$work/info-retained.json"
    python3 - "$work" "$retained_label" <<'PY'
import json
from pathlib import Path
import sys
work = Path(sys.argv[1])
original = json.loads((work / 'info-before.json').read_text())[0]['backup'][0]['label']
info = json.loads((work / 'info-retained.json').read_text())[0]
assert info['status']['code'] == 0 and len(info['backup']) == 2, 'Expected exactly two healthy retained backups'
assert all(item['type'] == 'full' and item['error'] is False for item in info['backup'])
labels = [item['label'] for item in info['backup']]
assert original not in labels and sys.argv[2] in labels
assert min(info['backup'], key=lambda item: item['timestamp']['stop'])['label'] == sys.argv[2]
PY
}

verify_restore_after_retention() {
    step 4 "Restore the oldest retained backup and replay WAL"
    # Reuse the existing restore implementation in a fresh volume, with the source stopped.
    image=$(docker inspect --format '{{.Image}}' "$primary_id")
    "${compose[@]}" stop postgres
    restore_runtime=(docker run --network "${PGDR_PROJECT}_repository" --no-healthcheck
        --volume "$restore_volume:/var/lib/postgresql/data"
        --volume "$work/pgbackrest.conf:/run/secrets/pgbackrest_s3:ro"
        --volume "$work/server.crt:/opt/s3-ca.crt:ro"
        --volume "$root/scripts/s3-entrypoint.sh:/opt/s3-entrypoint.sh:ro"
        --volume "$root/scripts/restore-volume.sh:/opt/restore-volume.sh:ro"
        --entrypoint bash)
    "${restore_runtime[@]}" --rm "$image" /opt/s3-entrypoint.sh \
        gosu postgres bash /opt/restore-volume.sh "$retained_label" "$recovery_time"
    "${restore_runtime[@]}" --detach --name "$restore_name" "$image" /opt/s3-entrypoint.sh \
        gosu postgres postgres -D /var/lib/postgresql/data \
        -c archive_mode=off -c archive_command= -c listen_addresses=
    wait_for_recovery
    restore_sql -c 'COPY (SELECT id, reference, amount_cents, created_at FROM orders ORDER BY id) TO STDOUT WITH CSV;' >"$work/retention-recovered.csv"
    cmp "$work/retention-expected.csv" "$work/retention-recovered.csv"
    [[ $(restore_sql -Atc 'SHOW archive_mode;') == off ]]
    restore_sql -c "INSERT INTO orders (reference, amount_cents) VALUES ('s3-retention-restored-write', 500);"
    [[ $(restore_sql -Atc "SELECT count(*) FROM orders WHERE reference = 's3-retention-restored-write';") == 1 ]]
    [[ -z $("${compose[@]}" ps --status running --quiet postgres) ]]
    docker inspect "$restore_name" >"$work/retention-restore-container.json"
}

write_report() {
    step 5 "Validate stored objects, historical versions, and report results"
    "${compose[@]}" exec -T moto python - <<'PY' >"$work/objects.json"
import boto3
import json
import sys
client = boto3.client('s3', endpoint_url='http://127.0.0.1:5000', region_name='eu-west-1',
                      aws_access_key_id='testing', aws_secret_access_key='testing')
objects = [item for page in client.get_paginator('list_objects_v2').paginate(Bucket='postgres-dr-fixture')
           for item in page.get('Contents', [])]
json.dump([{'key': item['Key'], 'size': item['Size']} for item in objects], sys.stdout)
PY
    "${compose[@]}" exec -T moto python - <<'PY' >"$work/versions.json"
import boto3
import json
import sys
client = boto3.client('s3', endpoint_url='http://127.0.0.1:5000', region_name='eu-west-1',
                      aws_access_key_id='testing', aws_secret_access_key='testing')
versions = [item for page in client.get_paginator('list_object_versions').paginate(Bucket='postgres-dr-fixture')
            for item in page.get('Versions', [])]
json.dump([{'key': item['Key'], 'current': item['IsLatest']} for item in versions], sys.stdout)
PY
    python3 - "$work" "$root/.local/reports/$PGDR_PROJECT-s3.json" "$PGDR_PROJECT" <<'PY'
import csv
import json
from pathlib import Path
import sys
work, output = map(Path, sys.argv[1:3])
before, after = (json.loads((work / name).read_text())[0] for name in ('info-before.json', 'info-after.json'))
assert before['status']['code'] == after['status']['code'] == 0
assert len(before['backup']) == len(after['backup']) == 1
original = before['backup'][0]['label']
assert after['backup'][0]['label'] == original
retained = json.loads((work / 'info-retained.json').read_text())[0]['backup']
labels = [item['label'] for item in sorted(retained, key=lambda item: item['timestamp']['stop'])]
label = labels[0]
container = json.loads((work / 'container.json').read_text())[0]
assert not container['HostConfig']['PortBindings']
assert all(mount['Destination'] != '/var/lib/pgbackrest' for mount in container['Mounts'])
assert not any(value.startswith(('AWS_ACCESS_KEY_ID=', 'AWS_SECRET_ACCESS_KEY=', 'AWS_SESSION_TOKEN='))
               for value in container['Config']['Env'])
objects = json.loads((work / 'objects.json').read_text())
assert objects and all(item['key'].startswith('postgres-dr/orders/') for item in objects)
assert any(f'/backup/orders/{label}/' in item['key'] for item in objects)
assert not any(f'/backup/orders/{original}/' in item['key'] for item in objects)
assert any('/archive/orders/' in item['key'] and item['key'].endswith('.gz') for item in objects)
versions = json.loads((work / 'versions.json').read_text())
assert any(f'/backup/orders/{original}/' in item['key'] and not item['current'] for item in versions)
with (work / 'retention-recovered.csv').open(newline='') as source:
    recovered = list(csv.reader(source))
assert len(recovered) == 3, 'Expected three recovered rows, including the post-backup WAL insert'
assert any(row[1] == 's3-retention-wal' for row in recovered)
assert not any(row[1] == 's3-retention-third' for row in recovered)
restore = json.loads((work / 'retention-restore-container.json').read_text())[0]
data = next(mount for mount in restore['Mounts'] if mount['Destination'] == '/var/lib/postgresql/data')
assert data['Name'] == sys.argv[3] + '_retention_restore'
assert all(mount.get('Name') != sys.argv[3] + '_pgdata' for mount in restore['Mounts'])
assert not restore['HostConfig']['PortBindings']
output.parent.mkdir(parents=True, exist_ok=True)
with output.open('x') as out:
    json.dump({'schema_version': 1, 'status': 'verified', 'backend': 'moto_s3_api_fixture',
               'project': sys.argv[3], 'backup_label': label, 'original_backup_label': original,
               'retained_backup_labels': labels, 'full_backups_created': 3,
               'recovered_rows_after_retention': len(recovered), 'post_backup_wal_replayed': True,
               'expired_backup_noncurrent_versions_preserved': True, 'object_count': len(objects),
               'stored_bytes': sum(item['size'] for item in objects),
               'off_host_recovery_verified': False}, out, indent=2)
    out.write('\n')
print(f'S3 API acceptance report: {output}')
PY
    echo 'PASS: full backup and WAL stored through S3 API; same backup available after primary recreation.'
    echo 'PASS: missing bucket rejected; no local repository mount or fallback; credentials copied with mode 0600.'
    echo 'PASS: three full backups retain two current copies; expired S3 object versions preserved.'
    echo 'PASS: oldest retained backup and later WAL recover 3 exact rows; later transaction excluded; new writes succeed.'
}

# Run one complete disposable acceptance scenario.
prepare_fixture
verify_backup_and_recreation
verify_retention
verify_restore_after_retention
write_report
