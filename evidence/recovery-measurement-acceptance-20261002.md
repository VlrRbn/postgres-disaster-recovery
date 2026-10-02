# Recovery Measurement Acceptance Evidence

- Result: PASS
- Date: `2026-10-02`
- Source: working changes on `feat/recovery-measurement`, based on `6d9e1ae`
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `5.0.2`
- PostgreSQL: `17.11`; pgBackRest: `2.59.1`
- Full backup: `20261002-103006F`

## Acceptance Sequence

`make check` and `make acceptance` passed. The workflow YAML parsed successfully.
Three report tests verified monotonic timing despite reversed wall-clock stamps,
rejection of corrupt/missing or included post-target rows, and rejection of
invalid monotonic or rollback boundaries. GitHub CI is pending for this change.

## Measured Run

| Field | Observed Value |
| --- | --- |
| Recovery target | `2026-10-02 10:10:55.321343+00:00` |
| Incident observation after DELETE returned | `2026-10-02 10:10:55.563247+00:00` |
| Chosen rollback window | `0.241904 s` |
| Successful restore invocation | `2026-10-02T10:11:01.598985+00:00` |
| Data and new write verified | `2026-10-02T10:11:10.898088+00:00` |
| Recovery duration, monotonic clock | `9.299104 s` |
| Expected / recovered rows | `22 / 22` |
| Missing expected rows | `0` |
| Intentionally excluded post-target rows | `1` |
| Crash RPO seconds | Not measured (`null`) |

The duration includes the successful wrapper call, cached image build check,
restore, WAL replay, readiness wait, full row comparison, exclusion checks, and
a restored-side insert read back successfully. Restart checks ran afterwards,
outside the timing interval.

The raw report was retained in ignored `.local/reports/` after test cleanup.
It recorded HEAD as `6d9e1aeadd90fa8fc67b798c9dc543360a83b66f` and
`worktree_dirty: true`, reflecting these uncommitted changes.

## Cleanup And Regression

Existing persistence, backup, corruption, missing-WAL, occupied-target, physical
restore, and PITR acceptance checks passed. Source data and repository hashes
were preserved during recovery. Both test containers, the network, all three
test volumes, and temporary secret files were removed on exit.

## Scope And Interpretation

The run proves exact recovery of the wanted dataset and a measured duration
under these local conditions. The selected rollback window deliberately excludes
later transactions. It does not establish loss of acknowledged workload at an
unexpected crash or a production RTO objective. See
[measurement boundaries](../docs/recovery-measurement.md).
