# Point-In-Time Recovery

Recover a selected full backup to a UTC timestamp before an accidental deletion.
This extends [physical restore](physical-restore.md) using the same empty
`pgrestore` volume, read-only repository, disabled archiving, and isolated service.

## Recovery Contract

- Select the full backup explicitly with `BACKUP_LABEL`.
- Provide `RECOVERY_TIME` as `YYYY-MM-DD HH:MM:SS[.ffffff]+00:00`.
  UTC is required; local time zones and relative dates are rejected.
- Choose a time after the selected backup finished. Archived WAL must cover the
  recovery target, including a later transaction that lets recovery detect the
  stopping boundary. Merely choosing a future time does not make it reachable.
- pgBackRest uses `--type=time`, an inclusive target, and `--target-action=promote`.
  Transactions committed at or before the target are included. Later commits are
  excluded; row creation timestamps do not determine transaction commit order.
- `--target-timeline=current` follows the timeline of the selected backup.
  Recovery across later promoted timelines is outside this exercise.
- A malformed time is rejected before Docker starts. An unreachable target fails
  readiness and prints PostgreSQL logs; the partially restored volume is retained.

## Run A Controlled Exercise

Use synthetic data in the local lab. Start the primary and create a full backup
before inserting the demonstration order:

```bash
make up
make backup
make backup-info
make psql
```

Keep the printed backup label. Run these statements individually in the default
psql autocommit mode; do not wrap them together in a transaction:

```sql
INSERT INTO orders (reference, amount_cents) VALUES ('pitr-demo-001', 4500);
SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || '+00:00' AS recovery_time;
```

Copy the returned timestamp. Then simulate the mistake by deleting only this
demonstration order, and close the SQL session:

```sql
DELETE FROM orders WHERE reference = 'pitr-demo-001';
SELECT count(*) FROM orders WHERE reference = 'pitr-demo-001';
\q
```

The count should be zero. Archive the WAL containing the deletion and stop the
source before recovery:

```bash
make backup-check
make down
```

Use an empty restore volume. If an earlier restore occupies it, follow the
[repeat-restore procedure](physical-restore.md#repeat-restore-and-cleanup) first.
Replace both placeholders with the captured values:

```bash
BACKUP_LABEL=YYYYMMDD-HHMMSSF \
RECOVERY_TIME='YYYY-MM-DD HH:MM:SS.ffffff+00:00' make restore-time
make restore-psql
```

Inspect the recovered instance:

```sql
SELECT pg_is_in_recovery();
SHOW archive_mode;
SELECT reference, amount_cents FROM orders WHERE reference = 'pitr-demo-001';
\q
```

Expect `f`, `off`, and the recovered order with amount `4500`. The source still
contains the deletion. This command does not perform application cutover.

## Stop, Resume, And Retry

`make restore-down` stops and removes the restored container, retaining its data.
`make restore-up` resumes that copy. `make down` stops both services and retains
all data and backup volumes. `make restore-psql` opens the recovered database.

For a failed recovery, inspect `bash scripts/compose.sh logs restore`, correct
the timestamp, backup choice, or missing WAL, then use a fresh empty target as
described in the physical restore guide. Changing `RECOVERY_TIME` with
`make restore-up` does not perform a new recovery.

## Acceptance Criteria

`make acceptance` retains the physical restore checks and then requires:

- Missing UTC offset, invalid calendar dates, and missing targets are rejected.
- The source has 22 known orders before deletion, including post-backup commits.
- A timestamp is captured between the last wanted commit and a deletion of all
  orders; a later distinct order is inserted and its WAL archived.
- A future target beyond archived transactions fails without promotion.
- With the source stopped, the chosen target recovers all 22 rows byte for byte
  against the snapshot, including every field, and excludes the later order.
- Recovery ends, archiving stays off, and a new restored-side write survives restart.
- Source records and repository hashes are unchanged by recovery.
- All test containers and volumes are removed on exit. Fault injection and
  automatic volume deletion occur only in the unique disposable test project.

## References

Completed local run: [PITR acceptance evidence](../evidence/pitr-acceptance-20260930.md).

- [pgBackRest restore options](https://pgbackrest.org/command.html#command-restore)
- [PostgreSQL recovery targets](https://www.postgresql.org/docs/17/runtime-config-wal.html#RUNTIME-CONFIG-WAL-RECOVERY-TARGET)
- [PostgreSQL continuous archiving](https://www.postgresql.org/docs/17/continuous-archiving.html)
