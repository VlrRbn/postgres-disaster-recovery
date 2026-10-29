# Clean-Host S3 Recovery Acceptance Evidence

- Result: PASS
- Date: `2026-10-13`
- CI and review: [PR #12](https://github.com/VlrRbn/postgres-disaster-recovery/pull/12)
- Source: working changes on `feat/ec2-s3-recovery`, based on `fbb6daf`
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `5.0.2`
- PostgreSQL: `17.11`; pgBackRest: `2.59.1`
- Terraform: `1.14.4`; AWS provider: `6.47.0`
- EC2 environment: Ubuntu `24.04`, x86_64, Docker `29.1.3`, Compose `2.40.3`
- AWS account identifiers: anonymized as `123456789012`

## Validation

`make check` passed with 26 unit test methods, shell checks, and local/S3/fixture
Compose models. Terraform formatting and validation passed for the new temporary
host configuration. The pinned Terraform-container CI command also passed
without AWS credentials.

## S3 Restore Workflow

The existing `make s3-acceptance` passed with project
`postgres-dr-s3-test-1791892519-130350`. Recovery used `restore.sh` and the new
S3 Compose restore service, replacing the fixture's separate Docker-run setup.

| Scenario | Observed Result |
| --- | --- |
| Three full backups and expiration | Two current full backups retained; old object versions preserved |
| Selected recovery copy | Oldest retained backup `20261013-115555F` |
| PITR with source stopped | All three expected rows matched exactly; post-backup WAL row present; later row absent |
| Existing restore container | Another restore rejected before overwriting data |
| Nonempty restored volume after container removal | Restore rejected with `Restore target is not empty` |
| Recovered-side write and resume | New order retained after removing and recreating the restored container |
| Archiving and mounts | Archiving disabled; separate `pgrestore` volume; no source data mount or published port |

The fixture retained `26` current objects totaling `9,404,378 bytes`. The JSON
report is saved in ignored
`.local/reports/postgres-dr-s3-test-1791892519-130350-s3.json` and explicitly marks
off-host recovery as unverified. Cleanup removed the fixture containers, networks,
source/restore volumes, and temporary secrets/certificates.

## Local Regression

`make acceptance` passed existing persistence, backup verification and repair,
missing-WAL and occupied-target rejection, physical restore, and PITR. Physical
restore matched 20 complete records, and PITR matched 22 expected rows before
deletion. New writes survived restart. The disposable project removed its
containers, network, and three volumes.

## AWS Deployment

The authenticated plan contains eight additions: one EC2 instance, a VPC,
subnet, Internet gateway, route table, route association, security group, and
`AmazonSSMManagedInstanceCore` attachment to the existing reader role. It contains
no updates, replacements, or deletions of existing resources.

The planned host uses Ubuntu AMI `ami-071f50ad836e28841`, `t3.small`, an encrypted
16 GiB `gp3` root volume deleted on termination, and `postgres-dr-ec2-reader`.
IMDSv2 is required with response hop limit two. The security group defines no
inbound rules. The host receives an outbound public IPv4 address.

The saved Terraform plan applied successfully: eight resources added,
zero changed, and zero destroyed. Instance `i-0b435eaefafc30348` registered in
SSM with agent `3.3.4793.0`. Its bootstrap installed tools without initializing
PostgreSQL or copying AWS credentials.

## Source Boundary

The existing source created and verified full backup `20261013-120851F`, then
committed a unique synthetic order. A CSV snapshot captured all four fields of
nine rows. The recorded inclusive target was
`2026-10-13 20:09:52.952683+00:00`. A later synthetic transaction was committed
after that target to provide an explicit PITR stop boundary and an excluded row.
WAL delivery succeeded before the source was stopped and removed with
`make s3-down`. Its source data volume and S3 repository remained available for
future exercises. The local config was returned to instance mode without keys.

## Clean-Host Recovery

The fresh host checked out base commit `fbb6daf86a028f6caef61bc31cd95494059d6b27`
and received only four reviewed runtime files from the working tree through SSM:
`Makefile`, `compose.s3.yaml`, `scripts/compose.sh`, and `scripts/restore.sh`.
Their SHA-256 values matched the local runtime manifest after execution. The
comparison CSV was transferred as synthetic test input; no database files, backup
repository, passwords, or AWS credential files were transferred.

| Check | Observed Result |
| --- | --- |
| Fresh runtime | No Docker volumes existed before the first restore |
| AWS identity | `arn:aws:sts::123456789012:assumed-role/postgres-dr-ec2-reader/i-0b435eaefafc30348` |
| IMDSv1 request without token | HTTP `401` |
| Native pgBackRest S3 restore | Instance `auto` credentials; verified HTTPS; source remained stopped |
| Recovered data | All nine rows matched the source CSV exactly, including the post-backup WAL insert |
| Later transaction | Excluded from recovered data |
| Recovery state | `pg_is_in_recovery()` false; `archive_mode` off |
| New write | `ec2-restored-write`, amount `800`, survived container removal and recreation |
| S3 writer operations under reader identity | Actual `PutObject` and `DeleteObject` requests returned `AccessDenied` |
| Runtime isolation | Only `postgres-dr-s3_pgrestore` data volume; no local repository/source mount or published ports |
| Credential storage | Config mode `0600`, `repo1-s3-key-type=auto`, no stored AWS keys/token or AWS key environment variables |

The expected and recovered CSV SHA-256 was
`2248eb6620be2c28e4ccac96ffc1ef3df621b41899f7f8ec41879ad66848b74e`.
Boto3 was installed only as an audit tool to independently identify the role and
check denial of write/delete requests using a unique synthetic probe key. No
probe object was created or deleted. Native pgBackRest performed the recovery.

The verified JSON report is retained in ignored
`.local/reports/ec2-s3-recovery-20261013.json`. Before cleanup, the actual recovered
CSV, container inspection, report, and restore log were exported into
`.local/ec2-recovery-artifacts/` and checked locally.

## Cleanup

After evidence export, the reviewed destroy plan contained exactly eight deletes
for the temporary deployment. It excluded all S3 resources, reader/writer roles,
and instance profiles. Terraform cleanup completed with zero added, zero
changed, and eight destroyed resources.

Independent AWS reads confirmed the instance was terminated, its root EBS volume
and VPC no longer existed, and the SSM policy was detached from the reader role.
Both reader/writer instance profiles and objects under the verified backup's
prefix remained present. Temporary Terraform state contained no managed resources;
the repository state retained all 14 managed resources. The source stayed stopped,
its local `pgdata` volume remained present, and its config contained no AWS keys.
The cleanup receipt is saved in ignored
`.local/reports/ec2-s3-recovery-cleanup-20261013.json`.

## Interpretation

The result establishes recovery on a fresh EC2 host from the external AWS S3
repository with the source stopped, IMDS-backed reader credentials, exact data
validation, later-WAL replay, and a persistent new write. The local fixture also
verifies retention and occupied-target rejection. This exercise does not establish
an unattended backup schedule, long-duration credential-renewal behavior, or a
measured recovery objective for EC2 provisioning. See [clean-host recovery](../docs/ec2-s3-recovery.md)
for deployment, comparison, new-write validation, and cleanup.
