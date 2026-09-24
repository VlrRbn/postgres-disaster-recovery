# Delivery Roadmap

Public commits, pull requests, releases, and README sections use capability
names. Each release marks a completed and verified milestone.

| Public capability | Planned release | State |
| --- | --- | --- |
| Local PostgreSQL Foundation | `v0.1.0` | Complete locally |
| Physical Backup And WAL Archiving | `v0.2.0` | Planned |
| Point-In-Time Recovery | `v0.3.0` | Planned |
| Recovery Measurement | `v0.4.0` | Planned |

## Planned Acceptance

- **Physical Backup And WAL Archiving:** create a pgBackRest backup, restore into
  an empty target volume, verify a known dataset, and diagnose missing WAL.
- **Point-In-Time Recovery:** restore to a point before accidental deletion and
  verify both included and excluded transactions.
- **Recovery Measurement:** produce timestamped workload and recovery reports
  with explicit RPO and RTO measurement boundaries.

## Scope Rules

- Complete and review one milestone before starting the next.
- A milestone is complete only after its positive and negative checks pass.
- A public release follows PR merge and successful validation on `main`.
- Local reproducibility remains supported.
- Claim backup recovery only after restoration has been exercised.

Off-host backup storage, retention, alerting, replication, and failover are
possible later capabilities. Their scope and release targets are not yet defined.
