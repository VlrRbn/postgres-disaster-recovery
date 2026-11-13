# Patroni S3 Backup And Recovery

The optional S3 backend stores Patroni backups and archived WAL outside the
Docker host. The existing `patroni-backup` and `patroni-restore-time` commands
select it through `PGDR_PATRONI_REPOSITORY=s3`. The default remains local storage.

S3 uses a separate Compose project, `postgres-dr-patroni-s3`, and private directory,
`.local/patroni-s3`. It starts a new cluster; it does not copy the existing local
Patroni database or move its backup repository. Project-name guards prevent
accidentally reusing local data volumes with another archiving destination.
Its HAProxy endpoint uses `127.0.0.1:6433`, leaving the default local endpoint
on port `6432`. `PGDR_PATRONI_PORT` can override either port.

## Prepare AWS Permissions

Use the existing bucket and Terraform state in `terraform/s3-repository`.
For a first deployment, follow [S3 repository setup](s3-repository.md) to create
your own private variables file. Existing installations keep their current
`account_id`, `bucket_name`, `repository_prefix`, and `trusted_principal_arn`.

Add one field to your private variables file:

```json
"patroni_repository_prefix": "postgres-dr/patroni"
```

This is an additional JSON property, not a replacement for the whole file.
Run from the repository root with your authenticated bootstrap AWS profile:

```bash
export AWS_PROFILE=your-bootstrap-profile
terraform -chdir=terraform/s3-repository init
terraform -chdir=terraform/s3-repository plan \
  -var-file=../../.local/s3-repository.tfvars.json \
  -out=../../.local/patroni-s3.tfplan
```

Review the plan before applying it. For an unchanged existing installation,
enabling this field adds two roles, two inline policies, and two instance
profiles. It does not change the bucket or widen the standalone identities.

```bash
terraform -chdir=terraform/s3-repository apply ../../.local/patroni-s3.tfplan
terraform -chdir=terraform/s3-repository output patroni_s3_identities
```

The writer can list, read, write, and delete current objects only under the
selected Patroni prefix. The reader can list that prefix and read its objects.
Neither policy permits version deletion. Roles trust the configured bootstrap
principal for local profile use and EC2 for instance-profile use. No EC2 instance
is created. With `patroni_repository_prefix = null`, these identities are absent.

## Configure And Start

Open a shell at the repository root. Replace the bucket, profile, and role ARN
with your own values from Terraform outputs:

```bash
export PGDR_PATRONI_REPOSITORY=s3
export PGDR_S3_BUCKET=your-postgres-dr-bucket
export PGDR_S3_REGION=eu-west-1
export PGDR_S3_PREFIX=postgres-dr/patroni
export PGDR_S3_AUTH_MODE=profile
export PGDR_S3_PROFILE=your-bootstrap-profile
export PGDR_S3_ROLE_ARN=arn:aws:iam::123456789012:role/postgres-dr-patroni-s3-writer

make patroni-s3-setup
make patroni-up
make patroni-backup-init
make patroni-backup
make patroni-backup-info
```

Keep the backend variable exported for subsequent Patroni commands. If your shell
still has standalone runtime overrides such as `PGDR_S3_DIR` or
`PGDR_PATRONI_PROJECT`, unset them before this procedure or choose explicit,
separate paths and a `postgres-dr-patroni-s3-*` project name. Setup rejects a
saved configuration for another runtime or bucket/prefix identity.

Setup preserves existing cluster passwords and TLS keys. S3 configuration is
written privately with mode `0600`; nothing under `.local` belongs in Git.
Profile mode exports temporary credentials into that private file. Refresh an
expired profile with `make patroni-s3-setup`, then use `make patroni-down` and
`make patroni-up` so both nodes install the refreshed configuration.

On EC2, attach the Patroni writer instance profile and use
`PGDR_S3_AUTH_MODE=instance`; unset `PGDR_S3_PROFILE` and `PGDR_S3_ROLE_ARN` before
setup. pgBackRest obtains and refreshes credentials from IMDS automatically.
Container access to IMDS must be available; see [EC2 workload identity](ec2-workload-identity.md).

## Back Up Across A Leader Change

Use [Patroni recovery](patroni-recovery.md) to record a full backup label, UTC
target time, and numeric destination timeline. The same commands select the
current primary after promotion. Both nodes install the same S3 repository
settings, so the new primary archives to the same prefix.

```bash
make patroni-backup-check
make patroni-backup
make patroni-backup-info
make patroni-backup-verify
```

Retention keeps two completed full backups. Do not point another PostgreSQL
cluster at this prefix: its `orders` stanza belongs to one system identifier.
Different independent clusters need different child prefixes and IAM policies.

## Recover With A Reader Identity

Repository inspection and restore can use a separate configuration selected by
`PGDR_PATRONI_S3_RESTORE_DIR`. Prepare it with the reader role, keeping the writer
file in place:

```bash
PGDR_S3_RUNTIME=patroni \
PGDR_S3_DIR="$PWD/.local/patroni-s3/reader" \
PGDR_S3_ROLE_ARN=arn:aws:iam::123456789012:role/postgres-dr-patroni-s3-reader \
python3 scripts/setup_s3.py

export PGDR_PATRONI_S3_RESTORE_DIR="$PWD/.local/patroni-s3/reader"
make patroni-down
make patroni-backup-info
make patroni-backup-verify
```

On a replacement EC2 host, use the reader instance profile and instance-mode
configuration instead. Build the image with `make patroni-image`; source
PostgreSQL data, passwords, TLS identities, and etcd volumes are not required.
The restoration itself requires the S3 configuration, selected backup, and WAL.

Use your recorded values; the values below are examples:

```bash
BACKUP_LABEL=20261112-170000F \
RECOVERY_TIME='2026-11-12 17:05:00.000000+00:00' \
RECOVERY_TIMELINE=4 \
make patroni-restore-time

make patroni-restore-psql
```

```sql
SELECT id, reference, amount_cents FROM orders ORDER BY id;
SELECT pg_is_in_recovery();
SHOW archive_mode;
\q
```

Expect the chosen records, `f`, and `off`. An unreachable target fails.
Existing restore containers and nonempty restore volumes are refused.
`make patroni-restore-down` and `make patroni-restore-up` preserve restored writes.

Without a separate restore directory, inspection and recovery use the writer
configuration. Archiving is still disabled, but that IAM identity retains its
write permissions; use the reader configuration when enforcing read-only access.

## Network And Cleanup

Live nodes have a repository network for outbound S3/IMDS access. etcd remains
on the internal Patroni network. The recovery container has only the repository
network, a new data volume, scripts, and the S3 configuration; it has no source
data mounts or Patroni/DCS credentials and publishes no SQL port.
S3 traffic verifies certificates and hostnames. Recovery requires that network
access, unlike local-volume recovery, which uses `network_mode: none`.

```bash
make patroni-down
```

This removes the selected project's containers and networks, retaining source
and recovered data volumes, private configuration, and S3 objects. It does not
delete IAM resources. To return to local Patroni commands, unset the backend and
any explicit project/directory overrides in your shell.

## Validation

```bash
make check
make patroni-s3-acceptance
```

Acceptance extends the existing recovery scenario with an isolated TLS S3 API
fixture. It checks both writer and read-only recovery endpoints, rejects an
untrusted certificate, and removes source database/DCS volumes and private
identities before cross-timeline PITR. Object versions and delete markers must
remain unchanged during inspection and restoration. All test resources are
removed afterward; the report stays in `.local/reports/`.

The fixture verifies S3 API integration and recovery behavior. A live AWS run
also verified full backups before and after promotion, reader-role access with
the source stopped, recovery onto the promoted timeline, and retained restored
writes. That run used profile authentication on the existing Docker host;
replacement-host recovery and EC2 instance authentication for this backend
remain unverified. The recovered database does not rebuild etcd, rejoin Patroni,
schedule backups, or switch application traffic.

See [acceptance evidence](../evidence/patroni-s3-acceptance-20261112.md) and
[AWS recovery evidence](../evidence/patroni-s3-aws-acceptance-20261113.md).
Configuration reference:
[pgBackRest S3 configuration](https://pgbackrest.org/configuration.html#section-repository).
