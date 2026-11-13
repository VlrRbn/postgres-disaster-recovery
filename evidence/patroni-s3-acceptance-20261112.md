# Patroni S3 Acceptance Evidence

- Result: PASS
- Date: `2026-11-12`
- Source: working changes on `feat/patroni-s3-backups`, based on `1713c4d` (`v0.15.0`)
- Environment: Linux amd64, Docker Compose, local TLS S3 API fixture
- PostgreSQL: `17.11`; Patroni: `4.1.5`; pgBackRest: `2.59.1`
- Test project: `postgres-dr-patroni-s3-test-1793811290-42213`
- Original full backup: `20261112-166311F`, timeline `3`
- Promoted-primary full backup: `20261112-165655F`, timeline `4`
- Recovery target: `2026-11-12 16:56:44.479543+00:00`, timeline `4`

## Validation

`make patroni-s3-acceptance` passed all eight stages of the extended recovery
scenario. Full backups and archived WAL used the S3 API; no local repository
was mounted. Recovery selected the original backup after a leader change.

| Check | Observed Result |
| --- | --- |
| Existing configuration | The authenticated DCS archive update preserved unrelated parameters, system identifier, and exact records across restarts |
| Repository initialization | The current primary initialized the S3 stanza; verification rejected an empty backup set |
| Full backups | One backup completed on timeline 3 and another on the promoted primary on timeline 4 |
| TLS | Production configuration enabled certificate verification; an unrelated CA was rejected |
| Reader access | The separate TLS recovery endpoint allowed reads and rejected object writes and deletes with HTTP 403 |
| Failover WAL | A new order was committed and archived on timeline 4 through the promoted primary |
| Source removal | Both source database volumes, all three etcd volumes, source passwords, and cluster TLS identities were removed before recovery |
| Offline inspection | Backup metadata and integrity verification worked with the source containers and volumes absent |
| Invalid target | Timeline zero was rejected before recovery |
| Unreachable time | A future target failed with PostgreSQL's configured-target-not-reached error |
| Retry guards | Existing restore containers and nonempty target volumes were refused |
| Exact recovery | Three complete records matched the saved CSV, including the deleted order and post-failover order; the later order was absent |
| Restore state | PostgreSQL was out of recovery with archiving disabled and accepted a new synthetic write |
| Isolation | Recovery mounted only its data volume, scripts, fixture CA, and private S3 configuration; no local repository, source data, DCS credentials, or published SQL ports |
| Repository preservation | S3 object versions and delete markers were unchanged through failed and successful recovery and container recreation |
| Recreation | Four restored orders, including the local write, survived replacement of only the restore container |

The source system identifier was `7704360874938118192`. The normalized S3
version-metadata checksum was
`be0d2328da9a4a52c63532aa7f6c99ddbe1553551cc6ea75115ee352a414999e`.
This checksum covers object-version metadata and delete markers; pgBackRest
verification separately checked backup and WAL contents. The JSON report remains
at `.local/reports/postgres-dr-patroni-s3-test-1793811290-42213-patroni-s3.json`.

## Regression

`make check` passed 80 Python tests, shell syntax, ShellCheck, seven Compose
models, systemd definitions/calendars, and diff formatting. New tests cover the
nested Patroni data path, reserved prefix boundaries, private setup defaults,
configuration ownership, and refusal to reuse local/S3 project volumes.

`make patroni-backup-acceptance` passed the existing eight-stage local recovery
scenario. `make s3-acceptance` passed the existing five-stage standalone S3
scenario, including retention and recovery from the oldest retained backup.
Terraform formatting and validation passed without applying infrastructure.

Cleanup removed all disposable containers, volumes, and networks. Independent
Docker queries confirmed zero remaining resources for each completed project.

## Interpretation

Patroni backups and WAL remained usable through the S3 API after source data
and DCS volumes were removed. Recovery followed the explicit promoted timeline,
restored exact pre-deletion records, and preserved the repository.

These checks used a local API fixture with synthetic credentials. The read-only
fixture endpoint enforces HTTP methods; it does not validate AWS IAM policies.
Live AWS access, EC2 instance credentials for this backend, and a replacement-host
deployment remain unverified. No real AWS resources, host timers, or notification
settings were changed. The restored database remains separate from Patroni.
