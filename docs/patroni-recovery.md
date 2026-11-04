# Patroni Backup And Point-In-Time Recovery

The Patroni nodes share a local pgBackRest repository. Each primary archives
completed WAL segments there, including timeline history after promotion. Full
backups select the current primary through its verified Patroni API. Recovery
uses a separate PostgreSQL container with read-only access to the repository.

## Start And Prepare Backups

Run from the repository root. The commands use the same `PGDR_PATRONI_PROJECT`
and `PGDR_PATRONI_DIR` settings as the Patroni runtime.

For a new cluster:

```bash
make patroni-up
make patroni-backup-init
make patroni-backup
make patroni-backup-info
```

Fresh clusters enable archiving during bootstrap and create the `orders`
stanza after database initialization. `patroni-backup-init` also works for
an existing repository: it initializes missing metadata and checks WAL delivery.
It does not create a full backup.

## Upgrade An Existing Cluster

The existing DCS configuration takes precedence over bootstrap defaults.
For a cluster created before this release, start it with `make patroni-up` if
it is stopped, then run:

```bash
make patroni-backup-configure
make patroni-down
make patroni-up
make patroni-backup-init
make patroni-backup
```

`patroni-backup-configure` authenticates to the current primary's HTTPS API
and changes only `archive_mode`, `archive_command`, and `archive_timeout` in
DCS. Existing data and unrelated cluster settings are retained. The archive
mode requires restarting PostgreSQL, so stop application writes for this
restart. Both node containers then load the new settings and the repository
mounts. Changing only `bootstrap.dcs` would not update an existing cluster.

## Inspect And Verify

```bash
make patroni-backup-check
make patroni-backup-info
make patroni-backup-verify
```

`backup-check` selects the current primary and forces a WAL delivery check.
`backup` runs that check, creates a full backup, and verifies the result. A
role change during the operation fails the command; it is not retried silently.

`backup-info` and `backup-verify` use a disposable repository container with no
network and a read-only repository mount. They work while the live database
containers are stopped or removed, once the runtime image has been built.
Use `make patroni-image` to build that shared image without starting a database.
Verification rejects an empty repository and checks the pgBackRest report
explicitly, including versions that return zero with an error in the report.

The repository lives in `<project>_pgrepo`, separate from the local/S3 runtimes.
It retains two full backups. With `archive_mode=on`, a standby archives after
it becomes primary; this is not `archive_mode=always`.

## Record A Recovery Point

Create a full backup before the event you want to recover from and record its
label from `make patroni-backup-info`. After a failover, use the same repository;
the new primary continues archiving on a new timeline.

Use `make patroni-endpoint-psql` to add an order after failover, then record a
UTC target before deleting data:

```sql
INSERT INTO orders (reference, amount_cents)
VALUES ('patroni-pitr-after-failover', 3500);

SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC',
               'YYYY-MM-DD HH24:MI:SS.US') || '+00:00' AS recovery_time;
```

Also record the primary's numeric `TL` from `make patroni-status`. The target
timeline can be newer than the full backup's timeline. Explicit selection
avoids recovering onto an unintended branch in the archive.

After the destructive transaction, exit SQL and run `make patroni-backup-check`
to archive the WAL containing the target boundary and subsequent transaction.

## Restore Into A Separate Volume

Replace the example values below with your saved full-backup label, UTC target,
and destination timeline:

```bash
BACKUP_LABEL=20261103-220000F \
RECOVERY_TIME='2026-11-03 22:05:00.000000+00:00' \
RECOVERY_TIMELINE=4 \
make patroni-restore-time

make patroni-restore-psql
```

```sql
SELECT id, reference, amount_cents FROM orders ORDER BY id;
SELECT pg_is_in_recovery();
SHOW archive_mode;
\q
```

Expect the records from the chosen point, `pg_is_in_recovery() = f`, and
`archive_mode = off`. The restored database accepts local writes after
promotion, but does not publish WAL back into the source repository.

For recovery only to backup consistency, without a time target:

```bash
BACKUP_LABEL=20261103-220000F make patroni-restore
```

The restore commands refuse an existing restore container or a nonempty target.
They require an explicit full-backup label; time recovery also requires an
explicit numeric timeline. An unreachable target fails instead of returning
an earlier database as a successful restore.

## Isolation And Cleanup

The restore container runs PostgreSQL directly, with no Patroni process, DCS
connection, TLS secrets, published ports, or network. Its data volume is
`<project>_pgrestore`; neither live node's data volume is mounted. It ignores
the backed-up Patroni server settings and uses a local socket with archiving
disabled. pgBackRest's generated recovery settings remain active during replay.

```bash
make patroni-restore-down
make patroni-restore-up
```

`restore-down` removes the container while retaining restored data.
`restore-up` resumes that same database. `patroni-down` also removes the restore
container along with the live runtime; all data volumes remain.
To discard a failed or no-longer-needed restore before trying again, inspect it
first, then explicitly remove only its volume:

```bash
make patroni-restore-down
docker volume rm "${PGDR_PATRONI_PROJECT:-postgres-dr-patroni}_pgrestore"
```

## Validation And Limits

```bash
make check
make patroni-backup-acceptance
```

The disposable scenario verifies the existing-DCS upgrade, a pre-failover full
backup, post-failover WAL, and recovery to a point on the new timeline before
deletion. Another full backup is created on the new primary, while recovery
explicitly selects the original backup. All live services are removed before
restoration. It also tests an unreachable time, overwrite guards, exact records,
repository immutability, and retained restored writes after container recreation.

The restored database is a standalone recovery result. It does not replace the
live primary, rejoin Patroni, or restore etcd. The local repository shares the
Docker host; off-host storage for this runtime, scheduled Patroni backups,
tablespaces outside the data volume, and application cutover are separate work.
Asynchronous replication can still lose acknowledged transactions during failover.

See [acceptance evidence](../evidence/patroni-recovery-acceptance-20261104.md).

## References

- [pgBackRest recovery options](https://pgbackrest.org/command.html#command-restore)
- [PostgreSQL continuous archiving and timelines](https://www.postgresql.org/docs/17/continuous-archiving.html)
- [Patroni dynamic configuration](https://patroni.readthedocs.io/en/latest/rest_api.html#config-endpoint)
