# Backup Health Acceptance Evidence

- Result: PASS
- Date: `2026-10-05`
- Source: working changes on `feat/backup-health`, based on `3a9011a`
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `5.0.2`
- PostgreSQL: `17.11`; pgBackRest: `2.59.1`
- Test project: `postgres-dr-health-test-1790972251-48175`
- Full backup: `20261005-201746F`

## Validation

`make check`, `make backup-health-acceptance`, and `make acceptance` passed
locally. Fourteen unit test methods passed. The workflow YAML parsed successfully
and includes the new acceptance command and saved JSON report output.
An invalid zero backup-age limit returned Python exit `2` with no JSON stdout.
GitHub CI is pending for these working changes.

## Observed Health Results

The acceptance command used a `86400`-second backup-age limit and a `5`-second
archive timeout, except for the deliberately short stale-backup test.

| Scenario | Python Exit | Overall Status | Observed Condition |
| --- | --- | --- | --- |
| Uninitialized stanza | `1` | `unhealthy` | Repository metadata unavailable; no completed full backup; active archive check failed |
| Initialized, empty repository | `1` | `unhealthy` | No completed full backup; current WAL delivery passed |
| Completed backup | `0` | `healthy` | Backup age `1.198 s`; active WAL delivery passed |
| One-second age limit | `1` | `unhealthy` | Backup age `3.704 s`; age failed while WAL delivery passed |
| Archive write outage | `1` | `unhealthy` | Backup remained fresh; WAL delivery failed with pgBackRest error `082` after `5000 ms` |
| Permissions restored and primary restarted | `0` | `healthy` | Same backup label, age `15.374 s`; active WAL delivery passed |
| Primary stopped | `1` | `unhealthy` | All required checks failed; output remained valid JSON |

The healthy baseline already contained four historical archive failures from
the uninitialized-stanza phase. During the injected outage, `failed_count`
increased from `4` to `7`. The recovered primary still reported `7` and passed
health, confirming that historical failure counts do not cause a false alarm.

## Isolation And Cleanup

Archive write permissions changed only inside the unique disposable project.
Backups remained readable; no backup metadata or timestamps were edited.
The synthetic `health-preserved` order retained its expected amount, and the
completed full backup label was unchanged after the outage and restart.

The exit handler removed the test container, network, both named volumes, and
temporary password. The seven JSON snapshots remain together in the ignored
`.local/reports/postgres-dr-health-test-1790972251-48175-health.json` report.

## Regression

The separate `make acceptance` run passed existing container persistence,
backup corruption and repair, occupied-target and missing-WAL rejection,
physical restore, and PITR checks. PITR recovered all 22 expected rows exactly,
excluded the later transaction, and confirmed a new write surviving restart.
The regression project removed its own containers, network, and three volumes.

## Interpretation

The result verifies on-demand detection for a local full backup and active WAL
delivery. It does not establish scheduled monitoring, alert transport, backup
file integrity, or a recovery objective. See [backup health](../docs/backup-health.md)
for the command, limits, exit codes, and operational boundary.
