# Delivery Roadmap

Public commits, pull requests, releases, and README sections use capability
names. Each release marks a completed and verified milestone.

| Public capability | Planned release | State |
| --- | --- | --- |
| Local PostgreSQL Foundation | `v0.1.0` | Released |
| Physical Backup And Restore | `v0.2.0` | Released |
| Point-In-Time Recovery | `v0.3.0` | Released |
| Recovery Measurement | `v0.4.0` | Released |
| Backup Health | `v0.5.0` | Released |
| External Backup And Clean-Host Recovery | `v0.6.0` | Released |
| Streaming Replication | `v0.7.0` | Released |
| Controlled Switchover And Rejoin | `v0.8.0` | Released |
| Scheduled Backups And Health Checks | `v0.9.0` | Released |
| Backup Alerting | `v0.10.0` | Local and live delivery checks passed |

## Physical Backup Delivery Steps

The `v0.2.0` capability is delivered through three focused PRs. Each step is
verified and merged before the next starts; the release follows verified restore.

| Step | Merge Criteria | State |
| --- | --- | --- |
| PostgreSQL Image With pgBackRest | Build the image, verify tool versions, and pass existing persistence checks | Complete |
| Backup Repository And WAL Archiving | Configure repository storage, archive WAL, and create a checked physical backup | Complete |
| Physical Restore Acceptance | Restore into an empty target volume and verify data and new writes | Complete |

## Point-In-Time Recovery Delivery

PITR includes an explicit UTC time target, an accidental-deletion exercise,
and rejection of invalid or unreachable targets. Commands and acceptance criteria
are in [Point-In-Time Recovery](point-in-time-recovery.md).

## Recovery Measurement Delivery Steps

| Step | Merge Criteria | State |
| --- | --- | --- |
| Verified Restore Duration And Report | Monotonic timing around successful PITR, exact dataset validation, persistent JSON report, and explicit measurement boundaries | Complete |
| Acknowledged Workload And RPO | Record acknowledged transactions and quantify losses at a defined fault boundary | Complete |

Each step is reviewed and merged before the next begins. See
[recovery measurement](recovery-measurement.md) for the first step's contract.
The second contract is [acknowledged workload and RPO](acknowledged-workload-rpo.md).

## Backup Health Delivery

One PR delivers a JSON health command, configurable backup-age and archive-timeout
limits, failure detection, and a disposable acceptance scenario. Acceptance
requires successful current WAL delivery, rejects missing or stale backups and
an unavailable primary, and distinguishes recovered archiving from historical
error counters. See [backup health](backup-health.md).

## External Backup Delivery Steps

| Step | Merge Criteria | State |
| --- | --- | --- |
| AWS S3 Repository And WAL | Dedicated private bucket, prefix-scoped writer role, verified TLS, full backup and WAL, retention rollover with recovery, and operational docs | Merged in PR #10 |
| EC2 Workload Identity | Key-free instance-mode configuration and separate prefix-scoped writer/reader instance profiles | Merged in PR #11 |
| Clean-Host Recovery | Recover using only S3 objects on a fresh host/runtime, use a separate reader identity, compare expected data, and confirm new writes | Local/API checks and live EC2 recovery passed |

These steps shipped in
[v0.6.0](https://github.com/VlrRbn/postgres-disaster-recovery/releases/tag/v0.6.0).
See [S3 operations](s3-repository.md),
[EC2 workload identity](ec2-workload-identity.md), and the
[replacement-host recovery procedure](ec2-s3-recovery.md).

## Streaming Replication Delivery

Released in `v0.7.0`: a separate local primary/standby runtime, dedicated
replication credentials, asynchronous WAL streaming, a physical slot with bounded
retention, and operational commands. Acceptance compares exact records, rejects
standby writes, exercises outages on both sides, and verifies retained volumes
after container recreation. See [streaming replication](streaming-replication.md).

## Controlled Switchover Delivery

One PR extends the existing replication runtime with explicit promotion,
persistent startup fencing, and offline `pg_rewind` to rejoin the old primary.
It requires a reachable source and paused application writers. Acceptance covers
promotion guards, a new timeline, writable promoted service, rejected old-primary
startup, reversed streaming, read-only rejoined data, and role-aware recreation.
See [controlled switchover and rejoin](controlled-switchover.md).

Released in `v0.8.0` after merge and successful main CI.

## Scheduled Backup Delivery

One PR adds optional systemd user services and timers for the existing local
backup and health commands. It includes explicit configuration, UTC calendar
times, persisted catch-up, shared job locking, journald output, and lifecycle
commands. Acceptance verifies unit syntax, calendars, real job entrypoints,
contention, failure propagation, and safe configuration handling without enabling
host timers. A separate operator installation exercised services, a temporary
health timer, journal inspection, and a failure/recovery cycle. Normal calendar
firing and logout/reboot catch-up remain untested. See
[backup scheduling](backup-scheduling.md).

Released in `v0.9.0` after merge and successful main CI.

## Backup Alerting Delivery

One PR adds independently enabled Telegram and SMTP delivery to the existing
local scheduled jobs. Private configuration and per-project/job/channel state
support failure and recovery messages, repeat suppression, and retries on later
runs. Validation uses temporary loopback HTTPS and SMTP TLS servers, including
partial delivery and recovery. A separate operator exercise confirmed failure
receipt in Telegram/Gmail, suppression of repeated failures, and recovery
acceptance by both providers. See [backup alerting](backup-alerting.md).

## Acceptance Contracts

- **Physical Backup And Restore:** create a pgBackRest backup, restore into
  an empty target volume, verify a known dataset, and diagnose missing WAL.
- **Point-In-Time Recovery:** restore to a point before accidental deletion and
  verify both included and excluded transactions.
- **Recovery Measurement:** produce timestamped workload and recovery reports
  with explicit RPO and RTO measurement boundaries.
- **Backup Health:** detect missing or stale completed full backups and failed
  current WAL delivery; report successful recovery after an archive outage.
- **External Backup And Clean-Host Recovery:** preserve backups and WAL outside
  the source host, then verify recovery without its local database or repository.
- **Streaming Replication:** compare exact data, reject standby writes, and verify
  catch-up and persistence after outages and container recreation.
- **Controlled Switchover And Rejoin:** stop and fence the old primary before
  promotion, rejoin it read-only, and retain reversed roles across recreation.
- **Scheduled Backups And Health Checks:** install explicit user units, preserve
  operator config, serialize jobs, create verified backups, and expose failures.
- **Backup Alerting:** report job failure and recovery to optional Telegram/SMTP
  channels, suppress accepted repeats, and retry a failed channel independently.

## Scope Rules

- A milestone is complete only after its positive and negative checks pass.
- A public release follows PR merge and successful validation on `main`.
- Local reproducibility remains supported.
- Claim backup recovery only after restoration has been exercised.

Retention rollover, independent external monitoring, and automatic failover
are possible later capabilities. Their scope and release targets are not yet defined.
