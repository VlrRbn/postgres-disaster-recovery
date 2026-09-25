# Backup Repository And WAL Archiving

This capability creates a physical backup of the PostgreSQL cluster and checks
that required WAL reaches a separate local repository. It verifies backup file
integrity and persistence across container recreation. Restoration into an empty
volume is the next delivery step.

## Storage And Configuration

| Resource | Location | Lifecycle |
| --- | --- | --- |
| PostgreSQL data | `pgdata` at `/var/lib/postgresql/data` | Retained by `make down` |
| Backups and archived WAL | `pgrepo` at `/var/lib/pgbackrest` | Retained by `make down` |
| pgBackRest configuration | `pgbackrest/pgbackrest.conf` | Mounted read-only |
| Stanza | `orders` | Describes the entire PostgreSQL cluster |

The image creates the repository mount point with owner `postgres` and mode
`0750`. A new Docker volume inherits those permissions. Backup commands execute
as `postgres` over the database's local socket.

Compose sets `wal_level=replica`, `archive_mode=on`, and an `archive_command`
that calls `pgbackrest --stanza=orders archive-push %p`. PostgreSQL's
`archive_timeout=60s` encourages WAL segment rotation when activity is low;
it is not a guaranteed RPO. The pgBackRest `archive-timeout=60` is a separate
limit on how long a check or backup waits for required WAL.

These PostgreSQL options are passed at startup and also apply to an existing
lab volume when its container is recreated. Schema initialization and password
rotation behavior remain unchanged.

## Start And Initialize

Run from the repository root:

```bash
make check
make up
```

`make up` builds the image, waits for PostgreSQL readiness, creates or reuses the
`orders` stanza, and checks WAL delivery. The check forces a WAL switch and waits
for that segment to appear in the repository. It does not create a full backup.

For a container started directly through Compose, initialize the repository with:

```bash
make backup-init
```

Repeating initialization validates the existing stanza instead of replacing it.
The database container remains running if initialization fails; inspect the error
and use `make down` if you want to stop it.

## Create A Full Backup

With PostgreSQL running:

```bash
make backup
make backup-info
```

`make backup` runs an archive check, takes a full physical backup, and validates
the repository. pgBackRest waits for the WAL required by the backup before
reporting success. `start-fast=y` requests an immediate checkpoint to begin the
backup. `make backup-info` displays the backup label, timestamps, and WAL range.

The configured retention is two completed full backups. After a third successful
full backup, automatic expiration can remove the oldest backup and WAL no longer
needed by the retained copies. This rollover is configured but not tested by the
single-backup acceptance scenario. No scheduled backup job is installed.

## Check Existing Backups

```bash
make backup-check
make backup-verify
```

`make backup-check` verifies current WAL delivery. It can pass before the first
backup because it checks archiving, not the existence of a completed copy.

`make backup-verify` first requires a completed backup in the stanza's JSON
metadata. It then runs `pgbackrest --output=text --verbose verify` and requires
an explicit `status: ok` report. pgBackRest 2.59.1 can return exit code zero while
reporting invalid files, so the wrapper checks the report rather than relying
only on the process exit code. Empty or invalid results produce a nonzero exit.

Integrity verification does not demonstrate that a restored database starts or
contains the expected application records. Those checks belong to the restore PR.

## Stop And Resume

```bash
make down
make up
make backup-info
```

Stopping removes the container and network while retaining both data and backup
volumes. Starting again reuses them and checks archiving. Removing the local
image also leaves both volumes intact; see [image cleanup](../README.md#remove-the-local-image).
Avoid adding `--volumes` to an interactive shutdown unless you intend to delete
both the database and its local backups.

## Acceptance Criteria

Run the complete disposable scenario:

```bash
make acceptance
```

Acceptance requires all of the following:

- A fresh repository fails `backup-check` with missing metadata, exit code `55`.
- Stanza initialization succeeds and can be repeated.
- Verification rejects a stanza with no completed backup.
- PostgreSQL reports archiving enabled and pgBackRest confirms WAL delivery.
- A full backup completes with a WAL range and healthy JSON metadata.
- Repository verification reports valid backup and WAL files.
- The same backup label remains available after container recreation.
- All existing order persistence, constraint, checksum, and new-write checks pass.
- Deliberately corrupting a compressed `PG_VERSION` file in the disposable copy
  causes `backup-verify` to fail, even though pgBackRest itself may exit zero.
- Replacing that test file with its saved original makes verification pass again.
- The test container, network, and both volumes are removed on exit.

The corruption step is internal to the isolated acceptance script. Interactive
`make backup` and `make backup-verify` never inject faults.
See [acceptance evidence](../evidence/backup-wal-acceptance-20260925.md) for the local run.

## Troubleshooting

| Symptom | Meaning And Next Step |
| --- | --- |
| Missing `archive.info` or `backup.info` | Run `make backup-init` after database startup; check that the intended repository volume is mounted |
| No healthy completed backup | Initialization is complete but no usable backup is recorded; run `make backup` |
| WAL archive timeout | Inspect `bash scripts/compose.sh logs postgres`, repository space and permissions, then retry `make backup-check` |
| Repository permission denied | Inspect `/var/lib/pgbackrest` ownership; the directory must be writable by `postgres` |
| Stanza belongs to a different database | Check which data and repository volumes are mounted; do not erase repository metadata to bypass the mismatch |
| Verification reports `status: error` | Treat the copy as invalid and investigate the named files before relying on it |

## Scope And Interpretation

Both volumes share one Docker host and failure domain. The repository is local,
unreplicated, and unencrypted. No off-host recovery, PITR, scheduled backup,
retention rollover, or RPO/RTO result is claimed. The physical restore acceptance
step must pass before release `v0.2.0`.

## References

- [pgBackRest User Guide](https://pgbackrest.org/user-guide.html)
- [Check Command](https://pgbackrest.org/command.html#command-check)
- [Verify Command](https://pgbackrest.org/command.html#command-verify)
- [Retention Configuration](https://pgbackrest.org/configuration.html#section-repository/option-repo-retention-full)
