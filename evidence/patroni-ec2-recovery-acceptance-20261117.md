# Patroni Clean-Host Recovery Acceptance Evidence

- Result: PASS
- Date: `2026-11-17`
- Documentation: working changes on `feat/patroni-ec2-recovery`
- Runtime: released `v0.16.0`, commit `57ae4b17ab6b2e2db2b972bc8552a8cac0bb6d61`
- AWS account identifiers: anonymized as `123456789012`
- Region: `eu-west-1`
- Instance: `<recovery-instance-id>`, `t3.small`
- AMI: `ami-0b27c8d40b81d75ef`, Canonical Ubuntu 24.04
- Reader role/profile: `postgres-dr-patroni-s3-reader`
- Repository: `example-postgres-dr-bucket`, prefix `postgres-dr/patroni`
- Original full backup: `20261113-102311F`, timeline `1`
- Recovery target: `2026-11-13 10:29:46.614562+00:00`, timeline `2`

Deployment-specific identifiers are anonymized. Original values remain in the
private run artifacts.

## Preparation

Terraform created eight temporary resources: EC2, six network resources, and
the SSM managed-policy attachment to the existing reader role. The root volume
was encrypted `gp3`, 16 GiB, with deletion on termination. AWS inspection
confirmed IMDSv2 was required with hop limit two and that the security group
had no inbound rules.

Cloud-init completed on the new host. Docker initially had no volumes, and
`/root/.aws/credentials` and `/root/.aws/config` were absent. The host checked
out the released runtime, built the image, and generated only instance-mode S3
settings. No source database files, local repository, passwords, TLS keys, or
AWS profiles were transferred. Standard checkout permissions made bind-mounted
scripts readable by the container user; private S3 configuration remained `0600`.

Observed tools were Docker `29.1.3`, Compose `2.40.3`, and Python `3.12.3`.
The image build preserved PostgreSQL `17.11` and verified Patroni `4.1.5`,
pgBackRest `2.59.1`, and Python dependencies.

## Validation

| Check | Observed Result |
| --- | --- |
| Source shutdown | The original local Patroni project had no containers during EC2 recovery |
| Reader access | Repository metadata and verification succeeded through the attached instance role, without profile credentials |
| Repository integrity | Both full backups were valid, with 1276 checked files each; all 11 checked WAL files were valid, with zero errors |
| Selected backup | The original timeline-1 backup was restored; the later `20261113-103051F` timeline-2 backup was not selected |
| Cross-timeline PITR | Recovery reached the explicit UTC point on timeline 2 |
| Exact comparison | All three recovered records matched every CSV field: ID, reference, amount, and timestamp |
| Source identity | The recovered system identifier matched the source cluster |
| Restore role | PostgreSQL was out of recovery with `archive_mode = off` |
| New writes | `ec2-patroni-restored-write`, amount 800, was inserted successfully |
| Recreation | The restore container ID changed; the new write remained, four orders were present, and archiving stayed off |
| IMDSv2 in Docker | A token-authenticated request inside the restored container returned the reader role and the expected EC2 instance ID |
| Private configuration | `repo1-s3-key-type=auto`, certificate verification enabled, no explicit access key, secret key, or session token; installed config was `600:postgres:postgres` |
| Mounts | Only the writable recovery volume and read-only restore scripts/S3 settings were mounted |
| Network | `postgres-dr-patroni-s3_repository`, with no published SQL ports |
| Services | Only the `restore` service ran; Patroni, etcd, and HAProxy were not started on EC2 |

The recovered references and amounts were:

| Reference | Amount (cents) |
| --- | ---: |
| `patroni-s3-001` | 1500 |
| `patroni-s3-002` | 2500 |
| `patroni-s3-after-failover` | 3500 |

The late source order was absent. The comparison snapshot reused the three
orders from the previously validated local recovery copy, excluding its later
local-only write. It was captured from a read-only snapshot with all stored
fields. Only this synthetic CSV was transferred as a comparison artifact.

Expected and recovered CSV SHA256:

```text
d6e1f2c34525b8e7e85b2c1dbb0e56c3307c2d90a3b09bbf1b4267ce2439ca5c
```

Successful restore validation started at `2026-11-17T10:17:28.404868+00:00` and
took `12.194` seconds through exact CSV comparison, database role checks, and
the first successful new write. This excludes EC2 provisioning, cloud-init,
image building, and container recreation. It is an observation from this run,
not an end-to-end outage duration or a recovery guarantee.

## Cleanup

The report, recovered CSV, image-build log, repository verification, and bootstrap
logs were exported before destruction. Terraform then deleted all eight temporary
resources. Independent AWS checks at `2026-11-17T10:22:36.403731+00:00` confirmed:

- EC2 was terminated and root EBS `<recovery-root-volume-id>` no longer existed.
- VPC, subnet, security group, route table, association, and Internet gateway were absent.
- `AmazonSSMManagedInstanceCore` was detached from the reader role.
- The recovery Terraform state was empty.
- Reader/writer roles and instance profiles remained available.
- The selected S3 backup manifest remained available.

Raw logs and CSVs remain outside Git in `.local/patroni-ec2-run-20261117/`.
The local source and its retained data volumes were not modified during the
EC2 run. No new repository objects or permanent IAM identities were created.

## Scope

This check validates the existing recovery runtime on a clean EC2 host using
reader instance credentials and S3 objects. It does not restore etcd, rebuild
the Patroni cluster, redirect application traffic, or test EC2 writer operation.
The source backup and target were reused from the earlier cross-timeline test;
no new failover was triggered during this run. Existing S3 setup tests passed
all 16 cases. Runtime scripts and Terraform resource definitions were unchanged.
