# Backup Repository And WAL Archiving Acceptance Evidence

- Result: PASS
- Date: `2026-09-25`
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `v5.0.2`
- Source: working changes on `feat/backup-wal-archiving`, based on `27cffbc`
- PostgreSQL: `17.11`
- pgBackRest: `2.59.1`
- Full backup label: `20260925-215639F`

## Acceptance Sequence

`make acceptance` built the database image and initialized an isolated Compose
project with fresh database and repository volumes:

```text
empty database and repository
  -> reject missing stanza metadata
  -> initialize stanza and archive WAL
  -> reject verification with no completed backup
  -> repeat initialization successfully
  -> insert 20 orders and create a full backup
  -> verify backup files and WAL
  -> recreate container and check retained records and backup
  -> reject a deliberately corrupted backup file
  -> replace the test file with its original and verify again
  -> remove test container, network, and both volumes
```

## Backup And WAL Results

The full backup completed with a reported size of `29.3MB` and `1270` files.
Its required WAL range was `000000010000000000000005` through
`000000010000000000000006`. JSON metadata reported one full backup without
backup errors, a nonempty WAL range, and the same label after container recreation.

The integrity report after container recreation showed:

```text
stanza: orders
status: ok
  archiveId: 17-1, total WAL checked: 7, total valid WAL: 7
    missing: 0, checksum invalid: 0, size invalid: 0, other: 0
  backup: 20260925-215639F, status: valid, total files checked: 1270, total valid files: 1270
    missing: 0, checksum invalid: 0, size invalid: 0, other: 0
```

## Failure Detection

The fresh repository was rejected with exit code `55` and a missing
`archive.info` diagnostic. The initialized repository with no completed backup
was rejected by the verification wrapper with exit code `1`.

The test replaced the contents of the backup's compressed `pg_data/PG_VERSION.gz`
file with invalid bytes. Verification reported `status: error`, and the wrapper
returned `1`. Replacing the test file with its saved original made verification
pass again. Only the disposable backup was modified; the live PostgreSQL data
files were not damaged.

## Foundation Regression

All 20 complete order records survived container recreation. A new insert
succeeded, the negative-amount constraint rejected an invalid order, and data
checksums remained enabled. The test container, network, and both volumes were
removed successfully.

`make check` passed Bash syntax, ShellCheck, Compose configuration, and whitespace
checks. `make image` also completed successfully. GitHub CI for this change is
pending.

## Scope And Interpretation

This run proves local WAL delivery, backup creation, integrity checks, and
failure detection. It does not demonstrate restoration into a new database,
retention expiration across multiple backups, off-host durability, PITR, or
RPO/RTO. Replacing a damaged test file is an integrity-test cleanup step, not a
database recovery exercise. Release `v0.2.0` still requires the restore PR.
