# Streaming Replication Acceptance Evidence

- Result: PASS
- Date: `2026-10-15`
- Source: working changes on `feat/streaming-replication`, based on `3e65549`
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `5.0.2`
- PostgreSQL: `17.11`; pgBackRest: `2.59.1`

## Validation

`make replication-acceptance` passed on an isolated temporary Compose project.
The primary initialized the `orders` table and a dedicated replication role.
The standby started from an empty volume using `pg_basebackup`, then received
asynchronous streaming WAL through the `standby` physical slot.

| Check | Observed Result |
| --- | --- |
| Initial replication | All 20 orders matched byte for byte as ordered CSV, including every column |
| Server roles | Primary returned `pg_is_in_recovery()=f`; standby returned `t` |
| Streaming state | One sender with application name `standby`, state `streaming`, and synchronization state `async` |
| Replication identity | Login and replication enabled; superuser, database creation, and role creation disabled |
| Slot retention setting | `max_slot_wal_keep_size=256MB` |
| Standby write | Insert rejected with SQLSTATE `25006` |
| Standby outage | Primary accepted another order; slot became inactive; resumed standby caught up to all 21 rows |
| Primary outage | Standby remained readable with 21 rows and stayed in recovery |
| Primary restart | Streaming resumed and the next write reached the standby; all 22 rows matched |
| Unsafe target | Removing the standby marker made startup fail without overwriting data; restoring it allowed resume |
| Container recreation | Both containers were removed and recreated on their retained volumes; all 22 rows matched |
| Port publication | Neither service published a host port |

Replay comparisons waited for an explicit primary WAL position with a 60-second
deadline. The completed run removed its containers, internal network, both named
volumes, and temporary secrets. Cached images and build layers remain.

## Regression

`make check` passed shell syntax, ShellCheck, all 26 existing unit test methods,
and the local, S3, S3 fixture, and replication Compose configurations.

`make acceptance` passed existing persistence, full backup, integrity verification,
physical restore, PITR, unsafe-target rejection, and missing-WAL detection. Its
PITR comparison recovered 22 exact records, and restored-side writes survived
restart. The disposable regression project removed its containers and volumes.

## Interpretation

This result proves local asynchronous streaming, read-only standby behavior,
short-outage recovery, and persistence across container recreation. Both services
share one Docker host. It does not establish host-failure tolerance, zero-loss
failover, TLS transport, automatic promotion, or standby reseeding after WAL loss.
GitHub CI is pending for these working changes.
