# Physical Restore

This exercise restores an explicitly selected full backup into an empty volume,
starts a separate PostgreSQL instance, and verifies recovered application data.
The source database can remain stopped throughout recovery.

## Storage And Isolation

| Service | Data Volume | Repository Access | Network |
| --- | --- | --- | --- |
| `postgres` | `pgdata` | Read/write | Internal Compose network |
| `restore` | `pgrestore` | Read-only | `none`; SQL access uses the local container socket |

The restore service uses the same Dockerfile as the source. Its profile prevents
normal `make up` from starting it. It mounts no source data volume, initialization
SQL, or password file. The restored cluster already contains its database roles
and authentication configuration.

The service starts PostgreSQL directly instead of invoking the image's initdb
entrypoint. Starting an empty target therefore fails rather than silently
creating a fresh database. WAL archiving is disabled by both the restore command
and the server startup options, so the recovered instance cannot publish a new
timeline into the source repository.

## Prepare A Backup

Run from the repository root using the default project `postgres-dr-local`:

```bash
make up
make backup
make backup-info
```

Copy the full backup label from the output. Only labels shaped like
`YYYYMMDD-HHMMSSF` are accepted. An explicit label makes the selected copy
reviewable; the wrapper never silently selects the latest backup.

Stop the source if you want to exercise recovery without a running primary:

```bash
make down
```

Both the source data and the repository remain in their named volumes.
The restore path does not require the source container to exist or be running.

## Restore And Inspect

Replace the placeholder with the label printed by `make backup-info`:

```bash
BACKUP_LABEL=YYYYMMDD-HHMMSSF make restore
make restore-psql
```

The wrapper builds the restore image, refuses an existing restore container,
and checks that the target volume is empty. It then invokes pgBackRest with
`--set`, `--type=immediate`, `--target-action=promote`, and `--archive-mode=off`.
It does not use `--delta` or `--force` and does not erase target files.

`immediate` recovers only until the selected backup becomes consistent. WAL
needed to reach that state is replayed, while later source transactions are
outside this target. This is not recovery to a user-selected timestamp.

The restored service becomes healthy only when SQL confirms that recovery has
finished. Inspect the recovered records:

```sql
SELECT pg_is_in_recovery();
SHOW archive_mode;
SELECT * FROM orders ORDER BY id;
INSERT INTO orders (reference, amount_cents) VALUES ('restore-demo-001', 3500);
\q
```

Expected recovery state is `f`, and archive mode is `off`. Use a new order
reference for each additional insert. This writes only to the restored database.

Inspect status or logs with:

```bash
bash scripts/compose.sh --profile restore ps
bash scripts/compose.sh logs --follow restore
```

`Ctrl+C` exits log following without stopping the service. The startup wait is
120 seconds by default; `RESTORE_WAIT_SECONDS` accepts integers from 10 to 300.
This is a readiness deadline, not an RTO measurement.

## Stop And Resume

Stop and remove only the restored container:

```bash
make restore-down
```

Resume the same recovered data without performing another restore:

```bash
make restore-up
make restore-psql
```

`make down` stops and removes both source and restored containers. All three
volumes are retained. If the restore image has been removed, rebuild it with
`bash scripts/compose.sh build restore` before `make restore-up`.

## Repeat Restore And Cleanup

A repeated `make restore` refuses to overwrite an existing target. Resume that
copy with `make restore-up`, or deliberately discard only its data to start over.
For the default project, the following deletes the restored copy and any new
records written to it; source data and backups are retained:

```bash
make restore-down
docker volume rm postgres-dr-local_pgrestore
```

If `PGDR_PROJECT` was overridden, use that project's restore volume name instead.
Then repeat `BACKUP_LABEL=YYYYMMDD-HHMMSSF make restore` with the intended label.
No cleanup command deletes the source or repository automatically.

## Failure Handling

| Failure | Behavior And Next Step |
| --- | --- |
| Missing or malformed backup label | Reject before invoking Docker; select a full label from backup information |
| Existing restore container | Refuse another restore; use `make restore-up` or remove the container with `make restore-down` |
| Nonempty target volume | Refuse to overwrite its contents; resume or deliberately remove only the restore volume |
| Unknown backup or damaged backup files | pgBackRest fails; inspect the error and treat any partially populated target as failed |
| Required WAL absent | PostgreSQL cannot complete recovery; the readiness check fails and the wrapper prints restore logs |
| Startup deadline reached | Return failure and retain the target for inspection; do not claim successful recovery |

After a failed attempt, correct the backup or WAL issue and use a new empty target.
The wrapper leaves partially restored files intact for inspection.
`make restore-down` can stop and remove a failed container without deleting its data.

## Acceptance Criteria

`make acceptance` runs the earlier foundation and backup checks, then requires:

- The source has 20 known orders at backup time and a distinct later committed
  order whose WAL is archived after the backup.
- The source is stopped before restoration and stays stopped until validation
  of the recovered instance is complete.
- A sentinel in a nonempty target causes refusal and remains unchanged.
- Withholding one required WAL segment causes a failed recovery, with the WAL
  name present in its diagnostics.
- Returning that segment and using a fresh target permits successful recovery.
- Every field of the 20 recovered orders matches the pre-backup CSV snapshot.
- The later source order is absent from the restored instance.
- Recovery has ended, archiving is off, and a new restored-side insert succeeds.
- That new record survives stopping and restarting the restored database.
- A restore request against an existing restored container is refused.
- Runtime mount inspection confirms a separate data volume, read-only repository,
  no source data mount, and no external network.
- Repository file paths and SHA-256 checksums match before and after recovery.
- After resuming the source, its order records match the pre-restore snapshot.
- Test containers, network, and all three volumes are removed on exit.

The missing-WAL mutation and target deletion are restricted to the unique
project created by the acceptance script. Interactive restore commands do not
inject faults. See [acceptance evidence](../evidence/physical-restore-acceptance-20260928.md).

## Scope And Interpretation

This is an isolated recovery clone on the same Docker host, not automatic
failover or application cutover. The original data volume remains present but
is not mounted by the recovered instance.

## References

- [pgBackRest Restore Command](https://pgbackrest.org/command.html#command-restore)
- [Recovery Type](https://pgbackrest.org/command.html#command-restore/category-command/option-type)
- [Disable Archiving On A Restored Cluster](https://pgbackrest.org/command.html#command-restore/category-command/option-archive-mode)
