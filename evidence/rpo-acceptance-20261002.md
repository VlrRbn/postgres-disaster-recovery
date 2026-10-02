# Acknowledged Workload And RPO Acceptance Evidence

- Result: PASS
- Date: `2026-10-02`
- Source: working changes on `feat/acknowledged-workload-rpo`, based on `dacb92d`
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `5.0.2`
- PostgreSQL: `17.11`; pgBackRest: `2.59.1`
- Full backup: `20261002-192639F`
- Last archived WAL before outage: `000000010000000000000006`

## Acceptance Sequence

`make check`, `make rpo-acceptance`, and `make acceptance` passed locally.
Seven report test methods passed and the workflow YAML parsed successfully.
GitHub CI is pending for these working changes.

## Workload And Fault

Ten sequential autocommit INSERTs returned successfully while PostgreSQL reported
`synchronous_commit = on` and `fsync = on`. Each returned row and host-observed
acknowledgment timestamp was flushed and fsynced to an independent host journal.

The first five orders were followed by a successful archive check. Archive
permissions were then changed only in the disposable repository to prevent
writes while preserving reads. The next five orders were acknowledged; a forced
WAL switch caused a confirmed increase in archiver failures. SIGKILL terminated
the primary with exit code `137`, and it remained stopped throughout recovery.

## Measured Run

| Field | Observed Value |
| --- | --- |
| Acknowledged transactions | `10` |
| Exactly recovered transactions | `5` |
| Lost acknowledged transactions | `5`: `rpo-006` through `rpo-010` |
| Last recovered acknowledgment | `2026-10-02T19:26:44.091033+00:00` |
| First lost acknowledgment | `2026-10-02T19:26:45.104417+00:00` |
| Last lost acknowledgment | `2026-10-02T19:26:46.608023+00:00` |
| Fault trigger | `2026-10-02T19:26:46.967883+00:00` |
| Observed RPO gap, monotonic clock | `2.876867 s` |
| Successful restore invocation | `2026-10-02T19:26:47.685844+00:00` |
| Data and new write verified | `2026-10-02T19:26:57.003762+00:00` |
| Verified recovery duration | `9.317908 s` |

Every stored field in the five recovered rows matched the corresponding host
journal prefix. The remaining five acknowledgments were absent. Recovery ended,
archive mode was off, and a new restored-side insert was read back successfully.

## Isolation, Cleanup, And Regression

Repository file paths and SHA-256 hashes were unchanged after archive outage,
crash, and restore. Docker inspection confirmed a dedicated `pgrestore` volume,
read-only repository mount, no `pgdata` mount, and network mode `none`.

The separate acceptance run passed existing persistence, backup, corruption,
missing-WAL, occupied-target, physical restore, and PITR checks. Both runs removed
their own containers, networks, volumes, and temporary passwords. The host journal
and JSON reports remain in ignored `.local/reports/`; images remain local.

## Interpretation

Recovery used only the selected backup and available archived WAL. The original
disk remained present but was unavailable to the restored instance. A normal local
crash restart using that disk would have different recovery material. These values
describe controlled archive-only recovery, quiesced writes, and host-observed
boundaries. See [the contract](../docs/acknowledged-workload-rpo.md).
