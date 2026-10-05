# Delivery Roadmap

Public commits, pull requests, releases, and README sections use capability
names. Each release marks a completed and verified milestone.

| Public capability | Planned release | State |
| --- | --- | --- |
| Local PostgreSQL Foundation | `v0.1.0` | Released |
| Physical Backup And Restore | `v0.2.0` | Released |
| Point-In-Time Recovery | `v0.3.0` | Released |
| Recovery Measurement | `v0.4.0` | Released |
| Backup Health | `v0.5.0` | Verified locally; PR and release pending |

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

## Acceptance Contracts

- **Physical Backup And Restore:** create a pgBackRest backup, restore into
  an empty target volume, verify a known dataset, and diagnose missing WAL.
- **Point-In-Time Recovery:** restore to a point before accidental deletion and
  verify both included and excluded transactions.
- **Recovery Measurement:** produce timestamped workload and recovery reports
  with explicit RPO and RTO measurement boundaries.
- **Backup Health:** detect missing or stale completed full backups and failed
  current WAL delivery; report successful recovery after an archive outage.

## Scope Rules

- A milestone is complete only after its positive and negative checks pass.
- A public release follows PR merge and successful validation on `main`.
- Local reproducibility remains supported.
- Claim backup recovery only after restoration has been exercised.

Off-host backup storage, retention, alerting, replication, and failover are
possible later capabilities. Their scope and release targets are not yet defined.
