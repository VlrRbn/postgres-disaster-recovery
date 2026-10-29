# Standby Reseed Acceptance Evidence

- Result: PASS
- Date: `2026-10-29`
- Source: working changes on `feat/standby-reseed`, based on `b37d9d0` (`v0.11.1`)
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `5.0.2`
- PostgreSQL: `17.11`; pgBackRest: `2.59.1`

## Validation

`make replication-acceptance` passed all 14 stages on disposable project
`postgres-dr-replication-test-1793269457-22694`. The existing streaming, TLS,
outage, fencing, and rejoin checks were extended with actual slot invalidation
and explicit reseeding before and after role reversal.

| Check | Observed Result |
| --- | --- |
| WAL loss | With the replica stopped, WAL records and 24 segment switches followed by a checkpoint exceeded the configured `256MB` slot limit; the physical slot became `lost` in both topologies |
| Ordinary restart | The replica logged removed WAL or an invalidated slot; its WAL receiver did not establish a connection |
| Target selection | Missing selection, the writable service name, and a healthy slot were rejected |
| Data identity | An unrelated system identifier, an alternate PGDATA path, and a missing standby marker were rejected |
| Unavailable source | Reseed refused while the primary was stopped |
| Transition state | Reseed refused after promotion but before the old primary completed rejoin |
| Failed copy | Replacing the fixture's trusted CA with an unrelated CA caused certificate verification failure before old data replacement |
| Preserved old data | The stopped standby's `global/pg_control` checksum and a sentinel file matched after the failed copy |
| Persistent guard | After removing the stopped container, fresh startup still refused the incomplete reseed; a different pending source identity was also rejected |
| Explicit retry | Restoring the CA and repeating `RESEED_NODE=standby make replication-reseed` succeeded with the pending operation's inactive replacement slot |
| Verified copies | Both successful base backups passed `pg_verifybackup` and matched the expected system identifier |
| Reversed roles | After switchover and rejoin, `RESEED_NODE=primary make replication-reseed` replaced the current read-only replica while service `standby` stayed writable |
| Primary continuity | Each writable source's `pg_postmaster_start_time()` stayed unchanged across WAL loss and reseeding |
| Streaming and writes | Rebuilt nodes were in recovery, slots were active with retained WAL, and new writes appeared through verified TLS |
| Recreation | After recreating the reversed topology, both nodes held 26 exact matching orders and SQL commands selected the current roles |

The scenario required the expected error diagnostics for negative checks rather
than accepting any failure. Old sentinel files disappeared after successful
replacement. Sender/receiver checks required encrypted streaming and configured
CA/hostname verification in both directions.

Cleanup removed the disposable containers, network, both data volumes, control
volume, temporary passwords/certificates, and topology lock. A separate Docker
query confirmed that no containers or volumes remained for the test project.
Those automated checks did not change interactive databases, host timers, AWS
resources, or notification providers.

Additional validation used the separate `postgres-dr-replication-recovery`
runtime with synthetic orders `reseed-demo-001` through `reseed-demo-006`.
In the initial topology, the slot became `lost` with reason `wal_removed`.
Restarting the standby logged that WAL segment `000000010000000000000003`
had been removed; it remained readable with two rows and no WAL receiver.
Explicit reseeding recovered the third row, and a subsequent fourth write
arrived through TLS 1.3 streaming.

After switchover and rejoin, service `primary` was read-only and the slot named
`primary` was also driven to `lost / wal_removed`. Reseeding that service recovered
all five current orders. The writable service's `pg_postmaster_start_time()`
remained `2026-10-29 15:00:56.031544+00` before and after the operation. A sixth
write and deliberate container removal/recreation preserved all six references
and amounts; the replica reported `transaction_read_only = on`. Data and control
volumes in this separate recovery runtime were retained.

## Regression

`make check` passed ShellCheck, shell syntax, 67 Python test methods, four Compose
configurations, systemd definitions/calendars, and diff formatting. This feature's
new operational checks extend the existing Docker scenario rather than adding
Python tests that mirror shell dispatch.

`make acceptance` passed the six-stage local backup and recovery scenario,
including corruption detection, exact-data restore, PITR, rejected unsafe
targets, and writable recovered databases. The replication regression also
retained the original read-only, TLS rejection, outage, promotion, fencing, and
offline-rejoin checks. Both rewind invocations reported `no rewind required`.

## Interpretation

The result verifies recovery from removed WAL with a reachable writable source
in the two supported stable topologies. The copy failure exercised retry before
old files were replaced. Host power loss, process termination during file
replacement, exhausted storage, extra tablespaces, and a pending operation whose
slot was missing were not separately exercised.

This does not provide automatic failover, recovery of an unfinished rejoin,
multi-host availability, or a zero-loss guarantee for asynchronous replication.
GitHub CI remains pending for these working changes.
