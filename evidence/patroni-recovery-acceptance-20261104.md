# Patroni Recovery Acceptance Evidence

- Result: PASS
- Date: `2026-11-04`
- Source: working changes on `feat/patroni-backups`, based on `8606efd` (`v0.14.0`)
- Environment: Linux amd64, Docker Compose
- PostgreSQL: `17.11`; Patroni: `4.1.5`; pgBackRest: `2.59.1`
- Test project: `postgres-dr-patroni-test-1793746028-106335`
- Full backup: `20261104-224825F`, timeline `3`
- Recovery target: `2026-11-04 15:02:53.931889+00:00`, timeline `4`

## Validation

`make patroni-backup-acceptance` passed all eight stages. The scenario took a
full backup before failover, archived changes from the promoted primary, and
recovered the selected state while all live services were removed. The new
primary also created full backup `20261104-224854F`;
recovery explicitly selected the original `20261104-224825F` set.

| Check | Observed Result |
| --- | --- |
| Existing configuration | Archive-disabled DCS settings were recreated, then updated through the authenticated HTTPS command; unrelated parameters, system identifier, and exact rows survived restart |
| Image contract | Build assertions preserved PostgreSQL and checked Patroni, pgBackRest, and Python dependencies |
| Empty repository | Verification rejected the absence of a completed backup |
| Full backups | Current-primary selection created a backup on timeline 3 and another on the new primary on timeline 4 |
| Failover | The replica became primary and HAProxy routed the new leader; a subsequent order was written on timeline 4 |
| Destructive change | An existing order was deleted and a late order added; both live nodes eventually reflected those changes |
| WAL delivery | The current primary's archive check passed after promotion and after the destructive transactions |
| Offline inspection | Backup metadata and repository verification worked after all live containers were removed |
| Input guard | Timeline zero was rejected before restore |
| Unreachable time | A future target failed with PostgreSQL's configured-target-not-reached error |
| Retry guards | An existing restore container and a retained nonempty target were both rejected |
| Cross-timeline PITR | The original timeline-3 backup recovered to the selected point on timeline 4 |
| Exact data | All three expected records matched every stored field; the deleted order and post-failover order were present, and the late order was absent |
| Restore role | The restored database was out of recovery with archiving disabled and accepted a local synthetic write |
| Isolation | No network, host ports, TLS secrets, or live PostgreSQL data mounts; repository mounted read-only |
| Repository integrity | File checksums were unchanged through failed and successful restores and container recreation |
| Recreation | Four restored records, including the new local write, survived recreation of only the restore container |

The source system identifier remained `7704080560350396463`. The normalized
repository-file checksum was
`e71c6c20c52da31c3de15c23b49685f390071f8704852d8cc0a4f28c68e3c207`.
The JSON report remains at
`.local/reports/postgres-dr-patroni-test-1793746028-106335-patroni-backup.json`.

## Regression

`make check` passed 75 Python tests, ShellCheck, shell syntax, five Compose
models, systemd declarations/calendars, and diff formatting. The added restore
guards reject absent, nonnumeric, zero, leading-zero, and out-of-range timelines,
invalid timestamps, and direct in-container recovery without an explicit timeline.

`make patroni-acceptance` passed all eight existing Patroni/HAProxy stages,
including TLS guards, acknowledged-loss measurement, rejoin, quorum recovery,
and recreation. `make acceptance` passed all six standalone backup/PITR stages,
including corruption detection, missing WAL, unsafe targets, and exact rows.
Workflow YAML parsing preserved both required check names.

Automated cleanup includes the restore/tools profiles. Independent Docker queries
confirmed that the completed projects retained no containers, volumes, or networks.

## Retained Cluster Recovery

Recovery also used the existing `orders-patroni` cluster with system
identifier `7703892033483468847`.

| Check | Observed Result |
| --- | --- |
| Original backup | `20261104-140826F`, timeline 10 |
| Promoted-primary backup | `20261104-141537F`, timeline 11 |
| Recovery point | `2026-11-04 15:21:00.321355+00:00`, explicitly targeting timeline 11 |
| Repository verification | All 23 checked WAL files and all 1276 checked files in each full backup were valid |
| Cross-timeline recovery | The original timeline-10 backup recovered `patroni-pitr-001` (10500), deleted `patroni-pitr-002` (11500), and post-failover `patroni-pitr-after-failover` (12500); `patroni-pitr-too-late` was absent |
| Restore state | `pg_is_in_recovery() = f` and `archive_mode = off` |
| Restored writes | `patroni-pitr-restored-write` (14500) remained after restore-container recreation, giving four selected test orders |
| Independent source | After the original cluster started again, its standby remained in recovery and showed `001`, `after-failover`, and `too-late`; the recovered copy retained its separate state |

## Interpretation

The backup and WAL archive remained usable across a primary change. Recovery
selected an explicit descendant timeline and recovered exact pre-deletion data
without using either live data volume or modifying the repository.

The DCS test recreated the archive-disabled settings used before this capability;
it did not restore or replace etcd. The recovered PostgreSQL instance is
standalone. No application cutover, scheduled Patroni backup, additional
tablespaces, or off-host repository was tested. These local checks do not
establish recovery after loss of the Docker host.

Automated mutations were confined to disposable resources and synthetic data.
The retained-cluster check changed the named synthetic test orders and preserved
both source and recovered data volumes. Host timers, notification settings, and
AWS resources were not changed.
