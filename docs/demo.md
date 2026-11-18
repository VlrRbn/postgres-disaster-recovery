# Local Failover And Recovery Demo

Demonstrate writes through HAProxy, automatic Patroni promotion, and recovery
of an accidentally deleted order across timelines. This uses a separate local
Compose project with synthetic data. AWS credentials and cloud resources are
not required. Allow time for the first image pull and build.

Run from the repository root in one Bash terminal. Docker with Compose, Python 3,
OpenSSL, and Make must be available. Commands use the existing runtime scripts.

## Start A Separate Project

```bash
export PGDR_PATRONI_REPOSITORY=local
export PGDR_PATRONI_PROJECT="postgres-dr-patroni-demo-$(date -u +%Y%m%d%H%M%S)"
export PGDR_PATRONI_DIR="$PWD/.local/$PGDR_PATRONI_PROJECT"
export PGDR_PATRONI_PORT=0
unset PGDR_S3_FIXTURE

make patroni-up
make patroni-status
```

Expect one `Leader`, one streaming `Replica`, and three healthy etcd members.
Either PostgreSQL service can be leader. Port `0` lets Docker assign an available
loopback host port; the SQL helper uses `haproxy:5432` inside the project network.
Keep these variables for the entire demo, including cleanup.

## Write And Back Up

```bash
make patroni-endpoint-psql
```

```sql
SELECT ssl, version FROM pg_stat_ssl WHERE pid = pg_backend_pid();

INSERT INTO orders (reference, amount_cents)
VALUES ('demo-001', 1500), ('demo-002', 2500);
\q
```

The TLS query should return `t`. Take a full backup, then inspect its label:

```bash
make patroni-backup-init
make patroni-backup
make patroni-backup-info
```

Save the printed full-backup label in this terminal, replacing the placeholder:

```bash
export BACKUP_LABEL=YYYYMMDD-HHMMSSF
```

Check that both orders reached the replica before deliberately crashing the
primary:

```bash
make patroni-standby-psql
```

```sql
SELECT reference, amount_cents FROM orders ORDER BY reference;
SELECT pg_is_in_recovery();
\q
```

Expect `demo-001`, `demo-002`, and `t`. This controlled setup waits for the
records; the runtime still uses asynchronous replication.

## Fail Over And Continue Through The Same Endpoint

Select the verified current primary and kill its container:

```bash
failed_node=$(bash scripts/patroni.sh primary-node)
bash scripts/compose.sh --patroni kill --signal SIGKILL "$failed_node"
make patroni-status
```

Repeat `make patroni-status` until the surviving node is leader. Election is
not immediate; configured lease and retry intervals are described in
[Patroni operations](patroni.md#stop-a-leader-and-observe-failover).

Open a new connection through the same helper after promotion:

```bash
make patroni-endpoint-psql
```

```sql
INSERT INTO orders (reference, amount_cents)
VALUES ('demo-after-failover', 3500);

SELECT reference, amount_cents FROM orders ORDER BY reference;

SELECT
    to_char(clock_timestamp() AT TIME ZONE 'UTC',
            'YYYY-MM-DD HH24:MI:SS.US') || '+00:00' AS recovery_time,
    ('x' || left(pg_walfile_name(pg_current_wal_lsn()), 8))::bit(32)::bigint
        AS recovery_timeline;
\q
```

Expect three orders. Save the exact timestamp and decimal timeline from the
query, replacing both example values below:

```bash
export RECOVERY_TIME='YYYY-MM-DD HH:MM:SS.ffffff+00:00'
export RECOVERY_TIMELINE=2
```

A fresh run normally promotes from timeline 1 to 2; use the actual query result.
HAProxy routes new connections to the primary. An existing session must reconnect;
it does not move between servers or replay transactions automatically.

## Delete An Order And Archive The Change

```bash
make patroni-endpoint-psql
```

```sql
DELETE FROM orders WHERE reference = 'demo-002';
INSERT INTO orders (reference, amount_cents) VALUES ('demo-too-late', 4500);
SELECT reference, amount_cents FROM orders ORDER BY reference;
\q
```

Now `demo-002` is absent and `demo-too-late` is present. The later insert also
provides a transaction boundary after the saved recovery time.

```bash
make patroni-backup-check
make patroni-down
make patroni-backup-verify
```

The WAL delivery check must pass before stopping the source. Verification then
uses the repository with no live database. The full backup label still refers
to the original pre-failover backup; keep it for recovery.

## Recover The Earlier State

```bash
make patroni-restore-time
make patroni-restore-psql
```

```sql
SELECT reference, amount_cents FROM orders ORDER BY reference;
SELECT pg_is_in_recovery();
SHOW archive_mode;
\q
```

Expected data:

| Reference | Amount (cents) |
| --- | ---: |
| `demo-001` | 1500 |
| `demo-002` | 2500 |
| `demo-after-failover` | 3500 |

The deleted order returns, the post-failover order remains, and `demo-too-late`
is absent. Expect `pg_is_in_recovery() = f` and `archive_mode = off`.

The restored database is separate from the stopped Patroni cluster. It mounts
its own recovery volume and the local repository read-only, has no network or
published SQL ports, and does not replace the live primary. See
[recovery isolation](patroni-recovery.md#isolation-and-cleanup).

## Stop Or Discard The Demo

To stop while keeping all volumes and private settings:

```bash
make patroni-down
```

To discard only the selected demo project's containers, networks, and volumes:

```bash
case "${PGDR_PATRONI_PROJECT:-}" in
    postgres-dr-patroni-demo-*)
        bash scripts/compose.sh --patroni --profile restore --profile tools \
            down --volumes --remove-orphans
        ;;
    *) echo 'Select the demo project before removing its data.' ;;
esac
```

Images, build cache, and the project's private directory remain. Running
`patroni-up` resumes the original cluster when its volumes are retained;
`patroni-restore-up` resumes the separate recovered database.

The demo covers one-host failover and PITR. Host-loss recovery is covered by
the separate [EC2 procedure](patroni-ec2-recovery.md) and
[completed AWS check](../evidence/patroni-ec2-recovery-acceptance-20261117.md).
