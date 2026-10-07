# AWS S3 Backup Repository

The S3 runtime sends pgBackRest full backups and archived WAL to a dedicated
AWS S3 bucket. It uses a separate Compose project and database volume, verified
HTTPS, and credentials stored outside Git. It mounts no local backup repository.

## Create The Bucket And Writer Role

Terraform in `terraform/s3-repository/` creates a general-purpose bucket with
public access blocked, bucket-owner-enforced ownership, SSE-S3 encryption,
versioning, and a bucket policy requiring HTTPS. A dedicated writer role can
list only the repository prefix and read, write, or expire its objects.
The bootstrap principal can assume this role; the role does not grant bucket
administration or access to other prefixes.

Prerequisites for this optional runtime: AWS CLI v2 with an authenticated profile,
Terraform `>= 1.6`, and Docker Compose `>= 2.24.4`. The local runtime still works
without AWS CLI or Terraform. The image includes a CA bundle for verified HTTPS.

Copy the example outside tracked files and fill in the intended account,
globally unique bucket name, region, and trusted IAM principal ARN:

```bash
mkdir -p .local
cp terraform/s3-repository/terraform.tfvars.example.json .local/s3-repository.tfvars.json
```

An SSO session's STS `assumed-role` ARN is not the IAM role ARN used in the trust
policy. Obtain the underlying role ARN with `aws iam get-role` through the
bootstrap profile, or use an existing IAM principal allowed to provision resources.

```bash
export AWS_PROFILE=your-bootstrap-profile
terraform -chdir=terraform/s3-repository init
terraform -chdir=terraform/s3-repository plan \
  -var-file=../../.local/s3-repository.tfvars.json \
  -out=../../.local/s3-repository.tfplan
terraform -chdir=terraform/s3-repository apply ../../.local/s3-repository.tfplan
```

Review the plan before applying. `allowed_account_ids` rejects credentials for
a different account. State stays in `.local/terraform/`; save that directory
securely to retain resource management. Commit `.terraform.lock.hcl`, not provider
downloads, plans, state, or local settings. CI validates the Terraform configuration
without credentials and never applies it.

## Start The S3 Database

Set the bucket, region, bootstrap profile, and writer role from Terraform outputs:

```bash
export PGDR_S3_BUCKET=your-project-bucket
export PGDR_S3_REGION=eu-west-1
export PGDR_S3_PROFILE=your-bootstrap-profile
export PGDR_S3_ROLE_ARN=arn:aws:iam::123456789012:role/postgres-dr-s3-writer
make s3-up
make s3-psql
```

In the SQL shell, insert two synthetic orders and inspect the stored rows:

```sql
INSERT INTO orders (reference, amount_cents)
VALUES ('s3-demo-001', 1500), ('s3-demo-002', 2500)
ON CONFLICT (reference) DO NOTHING;

SELECT id, reference, amount_cents, created_at
FROM orders
WHERE reference IN ('s3-demo-001', 's3-demo-002')
ORDER BY id;

\q
```

The insert can be repeated: existing references are preserved without adding
duplicates. After leaving the SQL shell, create and check the backup from the
repository's terminal:

```bash
make s3-backup
make s3-info
make s3-health
```

The default S3 project is `postgres-dr-s3`, with its own `pgdata` volume.
An override must use a `postgres-dr-s3-*` name. This keeps S3 startup from
silently reusing the local lab's volume and changing its archiving destination.

`make s3-up` refreshes the S3 credential snapshot, builds/recreates the primary,
waits for readiness, initializes the stanza, and checks WAL delivery. It creates
no full backup on first startup. PostgreSQL publishes no host port and uses an
additional bridge network for outbound AWS access.

## Credentials And Refresh

`make s3-setup` prepares `.local/s3/pgbackrest.conf`, `settings.json`,
`writer-policy.json`, and the database password. With `PGDR_S3_ROLE_ARN` set,
setup obtains a one-hour STS session of the writer role. Without it, setup can
export credentials from an already restricted AWS CLI profile.

Keys and session tokens are written atomically with mode `0600`, mounted as a
Compose file secret, and copied inside the container to a `postgres`-owned
`0600` pgBackRest config before the official database entrypoint starts.
They are not passed through Docker environment variables or command arguments.
No IAM access key is created. The generated config inherits the tracked stanza,
archive timeout, and retention settings; it switches repository type/path to S3.

Non-secret repository settings are saved for later invocations. Changing bucket,
region, or prefix in an existing settings directory is refused before credentials
or files are changed. Use a separate `PGDR_S3_DIR` and project for a different
repository; do not switch an initialized cluster by bypassing this check.

These credentials are a lab snapshot, not an unattended refresh mechanism.
Before their expiry, run `make s3-up` again after authenticating the source
profile if needed. Recreation retains the S3 database volume. Stopping with
`make s3-down` retains all local secret/settings files for the next startup.

For an SSO-backed source profile, refresh it before startup when required:

```bash
aws sso login --profile your-bootstrap-profile
make s3-up
```

## Backup, Inspect, And Stop

With the S3 primary running:

```bash
make s3-backup
make s3-info
make s3-check
make s3-health
make s3-down
```

| Command | Result |
| --- | --- |
| `make s3-backup` | Check current WAL delivery, create a full S3 backup, and require a healthy integrity report |
| `make s3-info` | Display labels and archive ranges from S3 metadata |
| `make s3-check` | Force a WAL switch and wait for archive delivery to S3 |
| `make s3-health` | JSON backup-age and active archive-delivery report using the existing health contract |
| `make s3-down` | Remove S3 lab containers and networks; retain its database volume, passwords, and S3 objects |

pgBackRest writes below `postgres-dr/orders/` by default. Bundling combines small
backup files to reduce S3 requests. Retention keeps two completed full backups.
The role can expire current objects but cannot delete historical object versions.
With bucket versioning enabled, expiration does not immediately reclaim all stored
bytes. No S3 lifecycle deletion rule is installed, and WAL is not expired by an
independent age rule that could break retained backups.

Terraform protects the bucket from destroy and disables forceful object deletion.
`make s3-down` does not manage AWS resources. Deliberate AWS cleanup requires a
separate decision about all object versions, deletion protection, and state;
normal shutdown preserves backups.

## Acceptance And Boundaries

```bash
make check
make s3-acceptance
```

The CI scenario runs a digest-pinned Moto S3 API fixture behind a digest-pinned
Nginx TLS endpoint. OpenSSL generates a temporary certificate; pgBackRest trusts
only that fixture certificate and verifies its hostname. All services use a
unique internal Docker network, synthetic credentials, and no published ports.
The script never accesses AWS.

Acceptance checks full backup and WAL objects, integrity verification, continued
availability after primary recreation, rejection of a missing bucket, absence
of a local repository mount/fallback, mode `0600`, and credentials absent from
Docker environment values. It saves a JSON report under ignored `.local/reports/`
and removes its own containers, networks, volumes, temporary keys, and password.

The same script enables fixture bucket versioning, creates three distinct full
backups, and requires exactly the two newest copies in current metadata. Current
objects for the expired copy disappear while its noncurrent versions remain.
It then stops the source and reuses `restore-volume.sh` and `s3-entrypoint.sh` to
recover the oldest retained copy into a fresh volume. Recovery targets a time
after a post-backup insert and before the third backup's insert, proving that
required WAL survived expiration. All three expected rows must match every field,
the later row must be absent, and a recovered-side write must succeed.

This is a retention/recovery extension of `make s3-acceptance`, not a separate
script or operator restore command. The recovered fixture shares the Docker host
and uses synthetic credentials; it does not establish replacement-host recovery.

AWS acceptance is recorded separately in [S3 evidence](../evidence/s3-repository-acceptance-20261005.md).
It establishes real S3 upload, IAM prefix restrictions, verified TLS, and healthy
repository metadata. This first delivery does not yet establish recovery on a
clean replacement host; that is the next PR and the milestone's recovery contract.

## References

- [pgBackRest S3 Configuration](https://pgbackrest.org/configuration.html#section-repository/option-repo-s3-bucket)
- [pgBackRest File Bundling](https://pgbackrest.org/user-guide.html#backup/bundle)
- [AWS STS AssumeRole](https://docs.aws.amazon.com/cli/latest/reference/sts/assume-role.html)
- [S3 Versioning](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html)
