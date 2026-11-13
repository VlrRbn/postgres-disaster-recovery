# Patroni S3 AWS Recovery Acceptance Evidence

- Result: PASS
- Date: `2026-11-13`
- Source: working changes on `feat/patroni-s3-backups`, based on `1713c4d` (`v0.15.0`)
- Environment: local Docker Compose with AWS S3 in `eu-west-1`
- AWS account: `179151669003`
- Bucket: `vlrrbn-postgres-dr-179151669003-eu-west-1`
- Repository prefix: `postgres-dr/patroni`
- Project: `postgres-dr-patroni-s3`
- Cluster system identifier: `7707597922072338481`

## Validation

Terraform applied six additions: separate writer/reader roles, inline policies,
and instance profiles. The reviewed plan changed no existing resources. Profile
authentication assumed `postgres-dr-patroni-s3-writer` for backup and
`postgres-dr-patroni-s3-reader` for offline inspection and recovery.

| Check | Observed Result |
| --- | --- |
| Initial cluster | pg2 was leader and pg1 streamed on timeline 1; all six cluster/proxy services were healthy |
| Original full backup | `20261113-102311F`, completed at `2026-11-13 10:23:13+00`, used timeline 1 |
| Failover | Killing pg2 promoted pg1 to leader on timeline 2 |
| New-timeline write | `patroni-s3-after-failover` was committed with amount 3500 |
| Promoted-primary backup | `20261113-103051F`, completed at `2026-11-13 10:30:54+00`, used timeline 2 |
| Recovery target | `2026-11-13 10:29:46.614562+00:00`, with explicit destination timeline 2 |
| Destructive transaction | `patroni-s3-002` was deleted; `patroni-s3-too-late` was inserted with amount 4500 |
| Archive delivery | The current primary's WAL archive check completed successfully |
| Former leader | pg2 rejoined as a streaming replica on timeline 2 with reported lag 0 |
| Offline reader access | Metadata and verification succeeded through the reader configuration after removing the live cluster containers |
| Repository verification | All 11 checked WAL files were valid; each full backup had 1276 checked and valid files, with no missing, checksum, size, or other errors |
| Cross-timeline PITR | The original timeline-1 backup recovered the selected state on timeline 2 |
| Restore state | `pg_is_in_recovery() = f`, `archive_mode = off` |
| Restored writes | A new order with amount 5500 survived restore-container removal and recreation; archiving remained off |

Recovery used:

```bash
BACKUP_LABEL=20261113-102311F \
RECOVERY_TIME='2026-11-13 10:29:46.614562+00:00' \
RECOVERY_TIMELINE=2 \
make patroni-restore-time
```

The recovered references and amounts were:

| Reference | Amount (cents) |
| --- | ---: |
| `patroni-s3-001` | 1500 |
| `patroni-s3-002` | 2500 |
| `patroni-s3-after-failover` | 3500 |

The deleted order returned and `patroni-s3-too-late` was absent. After the new
write and container recreation, `patroni-s3-restored-write` with amount 5500 was
also present, giving four orders. These SQL checks compared references and
amounts; the disposable API scenario separately compares every stored field.

## Isolation

Docker inspection showed:

- Only `postgres-dr-patroni-s3_pgrestore` mounted as writable database storage.
- The reader's `pgbackrest.conf` mounted at `/run/secrets/pgbackrest_s3` read-only.
- Both restore scripts mounted read-only.
- No source database, etcd, or local backup repository volumes mounted.
- Network `postgres-dr-patroni-s3_repository`, with `ports={}`.

An independent container listing confirmed that only the healthy `restore`
service remained in this project after the source cluster was removed.

## Interpretation

The AWS S3 repository remained readable after a Patroni leader change and source
shutdown. The reader identity recovered a pre-failover backup using WAL from the
promoted timeline. The recovered database retained its own writes independently
of the source cluster.

The source volumes, recovered volume, private configuration, IAM identities, and
S3 objects were retained. No EC2 instance was created. This run used profile
authentication on the existing Docker host; it did not test this backend on a
replacement host or through EC2 instance credentials. It did not rebuild etcd,
switch application traffic, test AWS write-denial requests, or compare S3 object
versions before and after recovery. Those boundaries are separate from the
[disposable API checks](patroni-s3-acceptance-20261112.md).
