# Patroni Recovery On A Clean EC2 Host

Recover a Patroni backup and archived WAL from S3 on a new host using the
Patroni reader instance profile. The recovered database runs independently of
Patroni. Source database files, backup files, TLS identities, passwords, and AWS
profiles stay on the source host. Only a synthetic comparison CSV, backup label,
UTC target, and destination timeline are transferred.

The procedure reuses `terraform/ec2-recovery` and the existing recovery commands.
The released `v0.16.0` runtime contains everything needed on the new host.

## Prepare The Comparison

Follow [Patroni S3 recovery](patroni-s3-recovery.md) to create a full backup
before promotion and a post-failover order on the new timeline. Keep the source
writers paused while capturing the expected state. Record the original backup
label and actual WAL timeline; a later full backup must not replace the selected
pre-failover label.

On the source host, with `PGDR_PATRONI_REPOSITORY=s3` and the source cluster
running, capture every order field and the inclusive UTC target:

```bash
bash scripts/patroni.sh primary-psql -q \
  -c "SET TIME ZONE 'UTC'; COPY (SELECT id, reference, amount_cents, created_at FROM orders ORDER BY reference) TO STDOUT WITH CSV HEADER;" \
  > .local/patroni-ec2-expected.csv

bash scripts/patroni.sh primary-psql -Atq \
  -c "SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || '+00:00' AS recovery_time, left(pg_walfile_name(pg_current_wal_lsn()),8) AS timeline_hex;"
```

Convert the hexadecimal timeline to decimal for `RECOVERY_TIMELINE`, for example
`00000002` becomes `2`. With writers still paused, create a later transaction
boundary so recovery can stop at the saved target, then flush WAL and stop the
source:

```bash
bash scripts/patroni.sh primary-psql \
  -c "INSERT INTO orders (reference, amount_cents) VALUES ('ec2-patroni-after-target-' || to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYYMMDDHH24MISSUS'), 900);"
make patroni-backup-check
make patroni-down
base64 -w0 .local/patroni-ec2-expected.csv
```

The later order must be absent from the recovered database. An existing known
target and saved comparison snapshot can be reused while its full backup and
required WAL remain available. Avoid creating extra full backups during the
check: retention can expire the selected original backup.

## Plan The Temporary Host

The [shared EC2 recovery guide](ec2-s3-recovery.md#prepare-the-temporary-host)
describes host networking, IMDSv2, SSM access, costs, and cleanup. No inbound
rules or SSH keys are required. The host state remains
`.local/terraform/ec2-recovery.tfstate`; complete any existing deployment before
reusing it for this procedure.

On the workstation, copy the Patroni example to a new private variables file,
then set your real account ID and region. The role prefix selects the existing
`postgres-dr-patroni-s3-reader` role and instance profile:

```bash
cp terraform/ec2-recovery/patroni.tfvars.example.json \
  .local/ec2-patroni-recovery.tfvars.json

export AWS_PROFILE=your-bootstrap-profile
terraform -chdir=terraform/ec2-recovery init
terraform -chdir=terraform/ec2-recovery plan \
  -var-file=../../.local/ec2-patroni-recovery.tfvars.json \
  -out=../../.local/ec2-patroni-recovery.tfplan
```

Review the plan. With an empty recovery state, expect eight additions: one EC2,
six network resources, and an SSM policy attachment to the Patroni reader role.
No S3 resources or repository identities are created or replaced.

```bash
terraform -chdir=terraform/ec2-recovery apply ../../.local/ec2-patroni-recovery.tfplan
instance_id=$(terraform -chdir=terraform/ec2-recovery output -raw instance_id)
aws ssm describe-instance-information --region eu-west-1 \
  --filters "Key=InstanceIds,Values=$instance_id"
aws ssm start-session --region eu-west-1 --target "$instance_id"
```

Wait until SSM reports `Online` before connecting. Use your configured region
in these commands if it differs from `eu-west-1`.

## Prepare Only The Recovery Runtime

On EC2:

```bash
sudo -i
cloud-init status --wait
docker volume ls
umask 022
git clone https://github.com/VlrRbn/postgres-disaster-recovery.git /opt/postgres-disaster-recovery
cd /opt/postgres-disaster-recovery
git checkout --detach 57ae4b17ab6b2e2db2b972bc8552a8cac0bb6d61

export PGDR_PATRONI_REPOSITORY=s3
export PGDR_S3_AUTH_MODE=instance
export PGDR_S3_BUCKET=your-project-bucket
export PGDR_S3_REGION=eu-west-1
export PGDR_S3_PREFIX=postgres-dr/patroni
unset PGDR_S3_PROFILE PGDR_S3_ROLE_ARN
PGDR_S3_RUNTIME=patroni python3 scripts/setup_s3.py
make patroni-image
```

The checkout is the exact `v0.16.0` runtime commit. A fresh host should have no
Docker volumes before recovery. The setup command generates only S3 settings;
it does not generate Patroni TLS identities or database passwords. AWS CLI and
SSO configuration are not needed on EC2. pgBackRest retrieves temporary role
credentials from IMDS inside its container.

The checkout uses standard public file permissions so the container's PostgreSQL
user can read bind-mounted scripts. Setup writes private S3 settings with mode
`0600` independently of that checkout umask.

Use the [IMDS role-name check](ec2-s3-recovery.md#connect-and-prepare-recovery)
to confirm `postgres-dr-patroni-s3-reader`. The role-name endpoint contains no
credential document. Then inspect and verify the repository:

```bash
make patroni-backup-info
make patroni-backup-verify
```

Keep the source stopped. Run only the recovery commands on EC2; `patroni-up`
would attempt to initialize a separate cluster with a read-only identity.

## Restore And Compare

On EC2, replace the placeholders with the captured synthetic CSV, original
full-backup label, UTC time, and decimal destination timeline:

```bash
printf '%s' 'PASTE_SYNTHETIC_CSV_BASE64' | base64 --decode > .local/patroni-ec2-expected.csv
export BACKUP_LABEL=YYYYMMDD-HHMMSSF
export RECOVERY_TIME='YYYY-MM-DD HH:MM:SS.ffffff+00:00'
export RECOVERY_TIMELINE=2
make patroni-restore-time

bash scripts/compose.sh --patroni exec -T --user postgres restore \
  psql -X -q -v ON_ERROR_STOP=1 -U postgres -d orders \
  -c "SET TIME ZONE 'UTC'; COPY (SELECT id, reference, amount_cents, created_at FROM orders ORDER BY reference) TO STDOUT WITH CSV HEADER;" \
  > .local/patroni-ec2-recovered.csv
cmp .local/patroni-ec2-expected.csv .local/patroni-ec2-recovered.csv
make patroni-restore-psql
```

In SQL:

```sql
SELECT pg_is_in_recovery();
SHOW archive_mode;
INSERT INTO orders (reference, amount_cents) VALUES ('ec2-patroni-restored-write', 800);
\q
```

Expect `f`, `off`, and a successful insert. Recreate only the restored container:

```bash
make patroni-restore-down
make patroni-restore-up
make patroni-restore-psql
```

```sql
SELECT count(*) FROM orders WHERE reference = 'ec2-patroni-restored-write' AND amount_cents = 800;
SHOW archive_mode;
\q
```

Expect `1` and `off`. Docker inspection must show only the recovery volume,
scripts, and S3 instance-mode configuration. There must be no source data,
local repository, TLS identities, embedded AWS keys, or published SQL ports.
Outbound networking is required for S3 and IMDS.

## Evidence And Cleanup

Export the checked-out commit, AMI and instance IDs, reader role, backup label,
source/target timelines, UTC target, CSV checksum, recovered row count,
new-write persistence, and mounts/ports. Confirm that no source services were
running during recovery. Retain comparison CSVs and raw logs outside Git.

On the workstation, review and apply destruction of only this temporary host:

```bash
terraform -chdir=terraform/ec2-recovery plan -destroy \
  -var-file=../../.local/ec2-patroni-recovery.tfvars.json \
  -out=../../.local/ec2-patroni-recovery-destroy.tfplan
terraform -chdir=terraform/ec2-recovery show ../../.local/ec2-patroni-recovery-destroy.tfplan
terraform -chdir=terraform/ec2-recovery apply ../../.local/ec2-patroni-recovery-destroy.tfplan
```

Expect eight deletions, including the temporary SSM attachment. Keep the S3
repository, reader/writer roles, and instance profiles. The EC2 root volume and
its recovered database are deleted, so export evidence first.

## Validation

The [completed EC2 run](../evidence/patroni-ec2-recovery-acceptance-20261117.md)
used the released `v0.16.0` runtime and a previously validated comparison
snapshot. The original backup recovered across timelines through instance-role
authentication, every CSV field matched, and a new write survived recreation.
All temporary cloud resources were removed after exporting the report and logs.

## Scope

Success requires exact CSV equality, recovery onto the intended timeline,
confirmed instance-role access, new-write persistence, isolated mounts, and
completed cleanup. The recovered database is standalone. Restoring etcd,
rebuilding a Patroni cluster, and redirecting application traffic are separate
procedures. The temporary host, root volume, and public IPv4 incur charges
until removed.
