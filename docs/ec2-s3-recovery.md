# Clean-Host S3 Recovery

Recover a selected backup and archived WAL on a fresh EC2 host using the reader
instance profile. Transfer only a synthetic comparison snapshot, backup label,
and UTC target. The host receives no source database volume, local repository,
or AWS credential files. A completed AWS run is recorded in
[clean-host recovery evidence](../evidence/ec2-s3-recovery-acceptance-20261013.md).

## Prepare The Temporary Host

`terraform/ec2-recovery/` manages one Ubuntu 24.04 `t3.small` with an encrypted
16 GiB `gp3` root volume, IMDSv2, and response hop limit two. A dedicated VPC,
subnet, Internet gateway, route table, and security group provide outbound access
for SSM, package downloads, image pulls, and S3. There are no inbound rules or SSH
keys. The public IPv4 address, EC2 runtime, and EBS storage incur charges while
allocated; remove the temporary deployment after exporting evidence.
See [EC2 pricing](https://aws.amazon.com/ec2/pricing/on-demand/) and
[public IPv4 pricing](https://aws.amazon.com/vpc/pricing/).

The configuration also attaches `AmazonSSMManagedInstanceCore` to the existing
reader role for remote administration. Its S3 policy remains read-only and scoped
to the repository prefix. The separate host state manages this added attachment
and removes it during cleanup. See
[AWS SSM instance permissions](https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-instance-permissions.html).

Run from the repository root after provisioning the
[reader identity](ec2-workload-identity.md):

```bash
mkdir -p .local
cp terraform/ec2-recovery/terraform.tfvars.example.json .local/ec2-recovery.tfvars.json
```

Fill in your account, region, and role-name prefix. Authenticate your bootstrap
AWS profile, then generate and review the plan:

```bash
export AWS_PROFILE=your-bootstrap-profile
terraform -chdir=terraform/ec2-recovery init
terraform -chdir=terraform/ec2-recovery plan \
  -var-file=../../.local/ec2-recovery.tfvars.json \
  -out=../../.local/ec2-recovery.tfplan
terraform -chdir=terraform/ec2-recovery show ../../.local/ec2-recovery.tfplan
```

Expect eight additions, including the SSM attachment to the reader role. This
configuration reads the existing instance profile and manages no bucket, backup,
or S3 identity. Its state is `.local/terraform/ec2-recovery.tfstate`; retain the
existing S3 state separately. Apply after reviewing the plan and deciding to
create the temporary host:

```bash
terraform -chdir=terraform/ec2-recovery apply ../../.local/ec2-recovery.tfplan
instance_id=$(terraform -chdir=terraform/ec2-recovery output -raw instance_id)
```

Cloud-init installs Docker, Compose, Git, Make, and Python without initializing
PostgreSQL. The Ubuntu AMI includes SSM Agent; bootstrap starts it. See
[AWS Ubuntu SSM Agent](https://docs.aws.amazon.com/systems-manager/latest/userguide/agent-install-ubuntu-64-snap.html).

## Capture And Stop The Source

Use the source host's existing S3 writer configuration. If instance mode was
selected locally, explicitly restore `profile` mode and its profile/role settings
from [S3 startup](s3-repository.md#start-the-s3-database).

```bash
export PGDR_S3_AUTH_MODE=profile
export PGDR_S3_PROFILE=your-bootstrap-profile
export PGDR_S3_ROLE_ARN=arn:aws:iam::123456789012:role/postgres-dr-s3-writer
make s3-up
make s3-backup
make s3-backup-info
make s3-psql
```

Record the newest full backup label. In SQL, insert a unique post-backup order,
then exit. This row requires later archived WAL during recovery:

```sql
INSERT INTO orders (reference, amount_cents)
VALUES ('ec2-wal-' || to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYYMMDDHH24MISSUS'), 700);
\q
```

With no other application writers active, capture the dataset and inclusive UTC
target, archive the later WAL, and stop the source:

```bash
PGDR_REPOSITORY=s3 bash scripts/compose.sh exec -T --user postgres postgres \
  psql -X -v ON_ERROR_STOP=1 -U postgres -d orders \
  -c 'COPY (SELECT id, reference, amount_cents, created_at FROM orders ORDER BY id) TO STDOUT WITH CSV;' \
  > .local/ec2-expected.csv
PGDR_REPOSITORY=s3 bash scripts/compose.sh exec -T --user postgres postgres \
  psql -X -v ON_ERROR_STOP=1 -U postgres -d orders -Atc \
  "SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || '+00:00';" \
  > .local/ec2-recovery-time.txt
PGDR_REPOSITORY=s3 bash scripts/compose.sh exec -T --user postgres postgres \
  psql -X -v ON_ERROR_STOP=1 -U postgres -d orders \
  -c "INSERT INTO orders (reference, amount_cents) VALUES ('ec2-after-target-' || to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYYMMDDHH24MISSUS'), 900);"
make s3-backup-check
make s3-down
cat .local/ec2-recovery-time.txt
base64 -w0 .local/ec2-expected.csv
```

The final insert is deliberately later than the target. It gives PostgreSQL a
later commit boundary at which to stop PITR and must be absent from the recovered
snapshot. Archive it along with the included post-backup transaction.

Keep the source stopped. Transfer only this synthetic CSV comparison snapshot,
backup label, and UTC target; no data directories, backup files, or private configs.

## Connect And Prepare Recovery

On the workstation, check SSM registration and connect. Session Manager requires
the [local plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
alongside AWS CLI:

```bash
aws ssm describe-instance-information \
  --region eu-west-1 --filters "Key=InstanceIds,Values=$instance_id"
aws ssm start-session --region eu-west-1 --target "$instance_id"
```

On EC2, wait for bootstrap and check out the exact reviewed commit containing
the S3 restore commands. During PR validation use the commit pushed to your
feature branch:

```bash
sudo -i
cloud-init status --wait
git clone https://github.com/VlrRbn/postgres-disaster-recovery.git /opt/postgres-disaster-recovery
cd /opt/postgres-disaster-recovery
git checkout YOUR_REVIEWED_COMMIT
export PGDR_S3_AUTH_MODE=instance
export PGDR_S3_BUCKET=your-project-bucket
export PGDR_S3_REGION=eu-west-1
export PGDR_S3_PREFIX=postgres-dr/orders
unset PGDR_S3_PROFILE PGDR_S3_ROLE_ARN
make s3-setup
```

Check the attached role name without printing its credential document:

```bash
imds_token=$(curl --fail --silent --show-error --request PUT \
  --header 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
  http://169.254.169.254/latest/api/token)
curl --fail --silent --show-error \
  --header "X-aws-ec2-metadata-token: $imds_token" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/
unset imds_token
```

Expect the reader role. Do not run `make s3-up` on this host: it would initialize
a fresh source cluster and attempt repository writes. pgBackRest obtains
temporary IMDS credentials inside Docker when the restore accesses S3.

## Restore, Compare, And Resume

On EC2, save the transferred comparison snapshot and recorded target:

```bash
printf '%s' 'PASTE_SYNTHETIC_CSV_BASE64' | base64 --decode > .local/ec2-expected.csv
export BACKUP_LABEL=YYYYMMDD-HHMMSSF
export RECOVERY_TIME='YYYY-MM-DD HH:MM:SS.ffffff+00:00'
make s3-restore-time
PGDR_REPOSITORY=s3 bash scripts/compose.sh exec -T --user postgres restore \
  psql -X -v ON_ERROR_STOP=1 -U postgres -d orders \
  -c 'COPY (SELECT id, reference, amount_cents, created_at FROM orders ORDER BY id) TO STDOUT WITH CSV;' \
  > .local/ec2-recovered.csv
cmp .local/ec2-expected.csv .local/ec2-recovered.csv
make s3-restore-psql
```

In SQL, verify recovery finished and archiving is disabled, then write a new order:

```sql
SELECT pg_is_in_recovery(); -- must be false
SHOW archive_mode;          -- must be off
INSERT INTO orders (reference, amount_cents) VALUES ('ec2-restored-write', 800);
\q
```

```bash
make s3-restore-down
make s3-restore-up
make s3-restore-psql
```

```sql
SELECT count(*) FROM orders WHERE reference = 'ec2-restored-write' AND amount_cents = 800;
-- must be 1
\q
```

The recovered service mounts only its `pgrestore` volume and scripts, publishes
no ports, and has no local repository or source data mount. Its Docker bridge
allows outbound S3/IMDS access. Archiving stays disabled.

## Commands And Repeat Attempts

| Command | Result |
| --- | --- |
| `BACKUP_LABEL=... make s3-restore` | Recover the full backup's consistency point |
| `BACKUP_LABEL=... RECOVERY_TIME=... make s3-restore-time` | Replay WAL to an inclusive UTC target |
| `BACKUP_LABEL=... make s3-restore-latest-wal` | Replay available WAL on the selected backup's current timeline |
| `make s3-restore-psql` | Open the recovered SQL shell |
| `make s3-restore-down` | Remove the recovered container; retain its volume |
| `make s3-restore-up` | Resume the existing restored database |
| `make s3-down` | Remove all S3 project containers/networks; retain volumes and S3 objects |

A second restore refuses an existing container or nonempty target. Use a new
host or a separate `PGDR_PROJECT=postgres-dr-s3-...` for another exercise.

## Evidence And Cleanup

Export the commit, AMI/instance identifiers, reader role, backup label, UTC target,
row count, exact comparison result, new-write persistence, and Docker mounts/ports.
Keep synthetic snapshots and command logs outside Git. Publish an observation
report in `evidence/` after the complete AWS exercise passes.

On the workstation, review and apply cleanup only for the temporary deployment:

```bash
terraform -chdir=terraform/ec2-recovery plan -destroy \
  -var-file=../../.local/ec2-recovery.tfvars.json \
  -out=../../.local/ec2-recovery-destroy.tfplan
terraform -chdir=terraform/ec2-recovery show ../../.local/ec2-recovery-destroy.tfplan
terraform -chdir=terraform/ec2-recovery apply ../../.local/ec2-recovery-destroy.tfplan
```

Cleanup deletes the host and its root volume, network, and SSM attachment. The
S3 bucket, backups/WAL, reader/writer roles, and instance profiles remain managed
by `terraform/s3-repository/` and are retained.

## Validation And Scope

`make check` validates the local, S3, and fixture Compose models. The existing
`make s3-acceptance` uses the operational S3 restore commands to verify exact PITR
data, occupied-target rejection, and new-write persistence. `make acceptance`
checks local restore compatibility. CI validates both Terraform roots without
AWS credentials. Local fixture checks do not prove live EC2 IMDS or AWS recovery.
