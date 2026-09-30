# Point-In-Time Recovery Acceptance Evidence

- Result: PASS
- Date: `2026-09-30`
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `v5.0.2`
- Source: working changes on `feat/pitr-time-target`, based on `6d1beff`
- PostgreSQL: `17.11`
- pgBackRest: `2.59.1`
- Full backup: `20260930-165209F`
- Recovery target: `2026-09-30 16:52:55.905227+00:00`

## Acceptance Sequence

`make check` and `make acceptance` passed locally. The same acceptance run
retained the existing version, persistence, backup, corruption, missing-WAL,
occupied-target, and immediate physical restore checks.

After those checks, the source held 22 orders: 20 present at backup time,
`after-recreate`, and `pitr-before-delete`. The test captured a complete ordered
CSV snapshot and a UTC timestamp after the last wanted commit. It then deleted
all orders and inserted `pitr-after-delete`. WAL was archived before stopping
the source.

## Failure Detection

Missing time, missing UTC offset, and an invalid calendar date were rejected
with status `2`. A target one day beyond the captured timestamp caused startup
to fail; the wrapper printed `recovery ended before configured recovery target
was reached`. The test removed that failed disposable target before retrying.

## Recovery Results

Recovery to the captured timestamp returned all 22 rows byte for byte against
the complete pre-deletion CSV. Both post-backup orders were present and the
`pitr-after-delete` order was absent. The source remained stopped during recovery.

The restored instance reported `pg_is_in_recovery() = f` and `archive_mode = off`.
A new `pitr-restored-write` order was inserted; the full recovered dataset
remained identical after stopping and restarting the instance.

## Isolation And Cleanup

Repository file paths and SHA-256 checksums matched before and after the PITR
attempts. When resumed, the source still matched its damaged snapshot containing
only the post-deletion order. Restore-side writes did not reach the source.

Both containers, all three volumes, and the disposable project's network were
removed on exit. Images and build cache remain local.

## Scope And Interpretation

This verifies inclusive time-target recovery on the selected backup's timeline
using local archived WAL. It does not measure RPO/RTO, perform application
cutover, or establish off-host backup durability. See the
[PITR acceptance contract](../docs/point-in-time-recovery.md#acceptance-criteria).
