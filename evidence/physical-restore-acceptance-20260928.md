# Physical Restore Acceptance Evidence

- Result: PASS
- Date: `2026-09-28`
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `v5.0.2`
- Source: working changes on `feat/physical-restore`, based on `ccfeec2`
- PostgreSQL: `17.11`
- pgBackRest: `2.59.1`
- Selected full backup: `20260928-162202F`

## Acceptance Sequence

`make check` and `make acceptance` passed. Acceptance used a fresh project and
three dedicated volumes, retaining the earlier persistence and backup checks:

```text
20 original orders and a full backup
  -> source container recreation and a later order
  -> archive the later write and stop the source
  -> reject a nonempty restore target
  -> reject recovery with required WAL withheld
  -> return WAL and restore into a new empty volume
  -> compare all original records and exclude the later source order
  -> write to the restored database and restart it
  -> verify source and repository isolation
  -> remove all disposable resources
```

## Failure Detection

A sentinel file in the target caused restoration to return `1`; its contents
remained unchanged. The test then removed only its sentinel.

The test temporarily withheld required WAL segment
`000000010000000000000005` from the disposable repository. Recovery returned a
nonzero result, and diagnostics included that WAL name. The failed restore
container and volume were removed, the segment was returned, and restoration
was repeated against a new empty volume.

A further restore request while the recovered container existed was rejected
with exit code `1`.

## Recovery Results

pgBackRest reported restoring `29.3MB` across `1270` files. PostgreSQL completed
recovery, reported `pg_is_in_recovery() = f` and `archive_mode = off`, and returned
an exact CSV match for every field of the 20 orders stored before the backup.
The source-only `after-recreate` order was absent.

A new `restored-write` order was inserted, bringing the recovered instance to
21 records. Its complete dataset remained identical after restart.

## Isolation Results

The source container remained stopped during recovery and validation of the
restored database. Docker inspection confirmed:

- the recovered instance mounted the distinct `pgrestore` data volume;
- the backup repository mount was read-only;
- the source `pgdata` volume was not mounted;
- the restored container used network mode `none`.

Sorted repository file paths and SHA-256 checksums matched before and after
recovery, including the temporary WAL-withholding test. After the source was
resumed, its application records matched the source snapshot captured before
restoration. The restored-side insert did not appear in the source.

## Cleanup And Regression

Both test containers, the network, and all three volumes were removed. All prior
version, data checksum, order constraint, persistence, backup, and corruption
checks passed in the same run. Images and build cache remain local.

## Scope And Interpretation

The evidence establishes recovery from a selected physical backup with required
WAL while the source is stopped. The source data volume was retained throughout.
