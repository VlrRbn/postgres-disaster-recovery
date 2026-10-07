# AWS S3 Repository Acceptance Evidence

- Result: PASS
- Date: `2026-10-07`
- Source: working changes on `feat/s3-repository`, based on `4acffcc`
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `5.0.2`
- PostgreSQL: `17.11`; pgBackRest: `2.59.1`
- Terraform: `1.14.4`; AWS provider: `6.47.0`

## AWS Repository

Terraform created eight resources for a new dedicated bucket and writer role;
the reviewed plan changed and destroyed no existing resources.

| Field | Observed Value |
| --- | --- |
| Bucket | `vlrrbn-postgres-dr-123456789012-eu-west-1` |
| Region | `eu-west-1` |
| Repository prefix | `postgres-dr/orders` |
| Writer role | `postgres-dr-s3-writer` |
| Full backup | `20261007-120442F` |
| Records at backup | `5`: `s3-aws-1` through `s3-aws-5` |
| Records after later archived write | `6`, including `s3-aws-after-backup` |
| Current objects at observation | `20` |
| Sum of current object sizes | `7,363,682 bytes` |
| Server-side encryption | `AES256` |

AWS API reads confirmed the bucket's region, all four public access blocks,
enabled versioning, bucket-owner-enforced ownership, and an HTTPS-only bucket
policy. The size/count snapshot concerns current objects, not historical versions.

## Real Backup And WAL

The S3 primary has its own database volume and no local repository mount.
The selected bootstrap profile assumed the dedicated writer role; temporary keys
were prepared privately and copied into a `postgres`-owned `0600` pgBackRest config.
Docker environment inspection contained no AWS credential values. PostgreSQL
published no host port.

Verified HTTPS succeeded after the image was updated to include the previously
absent CA bundle. pgBackRest created a bundled full backup and explicitly reported
`status: ok`: all `1270` backup files and the six initial archived WAL files were
valid, with no missing, size, or checksum failures. A later sixth synthetic order
was followed by successful S3 WAL delivery and a healthy JSON report.

Using only the writer session, an independent AWS CLI read listed backup bundles
and WAL under the expected prefix and confirmed SSE-S3 on an archived metadata
object. STS identified the writer role. Listing `postgres-dr/outside/` returned
`AccessDenied`, confirming that the role does not grant unrestricted bucket listing.

`make s3-down` then removed the S3 primary and both networks. Its database volume,
local private settings/password, and remote backup/WAL objects were retained.
The AWS observation is saved in ignored
`.local/reports/s3-aws-acceptance-20261007.json`; the synthetic source snapshot is
retained in `.local/s3-aws-expected.csv`.

## CI API Fixture

`make s3-acceptance` passed against the separate digest-pinned Moto/Nginx fixture
with a generated trusted TLS certificate, synthetic credentials, and internal
networks. It verified a full backup and archived WAL, repository integrity, the
same backup after primary recreation, and an unchanged synthetic order.
The missing-bucket check failed, and no local backup fallback appeared.

Fixture backup `20261007-120435F` produced `17` current objects totaling
`7,215,927 bytes`. Its report explicitly marks the backend as a local API fixture
and does not claim off-host recovery. The exit handler removed all three
containers, two networks, the database volume, and temporary secrets/certificate.

## Retention Extension

The existing `s3-acceptance.sh` was extended and rerun with fixture bucket
versioning enabled. No additional script was created. Three full backups were
completed with distinct synthetic datasets:

| Backup | Result After Expiration |
| --- | --- |
| `20261007-124230F` | Expired from current metadata and current objects; noncurrent versions retained |
| `20261007-124255F` | Oldest retained copy, selected for recovery |
| `20261007-124312F` | Newest retained copy |

Exactly two full backups remained healthy in metadata. The current object
snapshot contained `26` objects totaling `9,404,763 bytes`; these values exclude
noncurrent object versions.

With the source stopped, the script reused `restore-volume.sh` and
`s3-entrypoint.sh` to recover `20261007-124255F` into a separate empty volume.
The UTC target `2026-10-07 12:43:11.232002+00:00` followed a post-backup insert
and preceded the third backup's insert. All fields of the three expected rows
matched the source snapshot, including `s3-retention-wal`. The later
`s3-retention-third` row was absent, and a new restored-side write succeeded.

Docker inspection confirmed the recovered container mounted only its dedicated
data volume, with no source data volume or published port. Recovery completed
with archiving disabled. Cleanup removed the additional restore container and
volume alongside the original fixture resources.
The extended report is retained in ignored
`.local/reports/postgres-dr-s3-test-1791236538-132265-s3.json`.

This demonstrates recovery after S3 retention in a local API fixture. It does
not claim clean-host AWS recovery or a separate reader identity.

## Static Checks And Regression

`make check` passed with twenty unit test methods, ShellCheck, both Compose
models, and diff formatting. The exact Terraform CI command passed in the pinned
Terraform container without AWS credentials. Workflow YAML parsed successfully.

The final `make acceptance` run used the updated image and passed existing
persistence, backup corruption/repair, missing-WAL and occupied-target rejection,
physical restore, and PITR. PITR recovered all 22 expected rows exactly, excluded
the later transaction, and confirmed a new write surviving restart. The regression
removed its containers, networks, volumes, and temporary password.

## Interpretation

This first PR establishes external backup storage and the working backup/WAL
path in AWS. One-hour credential snapshots support interactive lab runs. Clean
replacement-host recovery, unattended credential refresh, and restoration with a
separate reader identity remain the next delivery step. See
[S3 operations](../docs/s3-repository.md). GitHub CI is pending for these working changes.
