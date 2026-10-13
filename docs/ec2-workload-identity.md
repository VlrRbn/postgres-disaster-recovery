# EC2 Workload Identity

Use an EC2 instance profile to obtain temporary S3 credentials through IMDS.
The generated pgBackRest config contains repository settings and
`repo1-s3-key-type=auto`, without an access key, secret key, or session token.
This is the identity preparation step for clean-host recovery.

## Roles And Instance Profiles

The existing `terraform/s3-repository/` configuration adds two separate EC2
roles and instance profiles. Both trust only the EC2 service and use the existing
bucket and repository prefix.

| Profile | S3 Permissions | Purpose |
| --- | --- | --- |
| `postgres-dr-ec2-writer` | Prefix-scoped list, get, put, delete, and multipart operations | A database host creating backups and archiving WAL |
| `postgres-dr-ec2-reader` | Prefix-scoped list and get | A replacement host restoring existing backup and WAL objects |

The reader has no object write or deletion permissions. Neither profile grants
bucket administration or historical-version deletion. The existing
SSO-assumable writer role remains available for local development.

## Provision The Identities

Run these commands from the repository root. For a first deployment, create your
own local variables file from the tracked example:

```bash
mkdir -p .local
cp terraform/s3-repository/terraform.tfvars.example.json .local/s3-repository.tfvars.json
```

Edit the copied file with your AWS account ID, a globally unique bucket name,
region, and trusted IAM principal ARN.

IAM ARN of your SSO-role:

```bash
aws iam get-role \
  --profile aws-sso-admin \
  --role-name AWSReservedSSO_AdministratorAccess_1234567890123456 \
  --query 'Role.Arn' \
  --output text
```

See [S3 repository setup](s3-repository.md#create-the-bucket-and-writer-role) for
prerequisites and how to select the bootstrap principal.

For an existing deployment, reuse its variables file and Terraform state in
`.local/terraform/`; do not overwrite them with the example. When moving an
existing deployment to another machine, restore its state before planning.
An empty state does not discover or adopt existing AWS resources.

Authenticate your AWS CLI profile, then generate a plan locally:

```bash
export AWS_PROFILE=your-bootstrap-profile
terraform -chdir=terraform/s3-repository init
terraform -chdir=terraform/s3-repository plan \
  -var-file=../../.local/s3-repository.tfvars.json \
  -out=../../.local/ec2-identity.tfplan
terraform -chdir=terraform/s3-repository show ../../.local/ec2-identity.tfplan
```

`plan -out` creates `.local/ec2-identity.tfplan` on your machine. Review it, then
apply that generated plan and inspect the profiles:

```bash
terraform -chdir=terraform/s3-repository apply ../../.local/ec2-identity.tfplan
terraform -chdir=terraform/s3-repository output ec2_instance_profiles
```

For a fresh deployment, the plan includes the S3 bucket, the local-development
writer role, and both EC2 identities. When updating an existing S3 deployment
with its original state and unchanged settings, this adds six IAM resources:
two roles, two inline policies, and two instance profiles. Review any other
changes before applying. This configuration does not create an EC2 instance.
Local variables, plans, and state are generated or maintained by each operator
and stay outside Git; the tracked example and Terraform code are sufficient to
prepare a new deployment.

## Configure An EC2 Runtime

Attach the appropriate profile to a dedicated backup or recovery instance.
Require IMDSv2. Docker bridge networking needs an IMDS response hop limit of two:

```hcl
iam_instance_profile = "postgres-dr-ec2-reader"

metadata_options {
  http_endpoint               = "enabled"
  http_tokens                 = "required"
  http_put_response_hop_limit = 2
}
```

The application must be able to reach `169.254.169.254`. Native pgBackRest
`2.59.1` requests an IMDSv2 token, discovers the attached role, retrieves its
temporary credentials, and renews them before expiry. Credentials stay in the
process instead of the generated config. Treat IMDS access as access to the
host's role; use dedicated hosts with the smallest required role.

## Prepare The Config Without Keys

On the EC2 host, select instance authentication and the existing repository:

```bash
export PGDR_S3_AUTH_MODE=instance
export PGDR_S3_BUCKET=your-project-bucket
export PGDR_S3_REGION=eu-west-1
export PGDR_S3_PREFIX=postgres-dr/orders
unset PGDR_S3_PROFILE PGDR_S3_ROLE_ARN
make s3-setup
```

Instance mode requires no AWS CLI, SSO login, or bootstrap profile. Setup writes
the config and non-secret settings with mode `0600` and retains the existing
database-password behavior. It does not request credentials or connect to IMDS;
pgBackRest does that when it accesses S3.

The same preparation command can run locally to inspect the config. Real S3
operations in instance mode require an EC2 host with an attached profile and
reachable IMDS. Starting a fresh database against an existing repository would
use a different cluster identity: the next recovery step will populate an empty
data volume from the selected backup before database startup.

## Authentication Modes

| Setting | Behavior |
| --- | --- |
| `PGDR_S3_AUTH_MODE=profile` | Default local-development behavior: obtain an STS snapshot through AWS CLI and store it privately |
| `PGDR_S3_AUTH_MODE=instance` | Generate an `auto` config without keys; pgBackRest uses the attached EC2 role |

Authentication mode is saved in `settings.json`. Switching an existing settings
directory to instance mode atomically replaces its old config and removes the
previous access key, secret, and token fields. It preserves the repository
identity guard for bucket, region, and prefix. It does not revoke previously
issued sessions or remove separately published copies of an old config.

Switching to instance mode also clears saved `profile` and `role_arn` values.
Explicit `PGDR_S3_PROFILE`, `PGDR_S3_ROLE_ARN`, `--profile`, or `--role-arn` inputs
are rejected in instance mode: only the attached EC2 role supplies credentials.
Unset the environment variables and omit these arguments before setup.

For local development after using instance mode, explicitly select `profile`
and supply an authenticated restricted profile or the existing writer role.
S3 bucket objects and database data are unaffected by configuration preparation.

## Validation And Scope

```bash
make check
make acceptance
make s3-acceptance
```

Unit checks cover key-free configuration, no AWS CLI calls in instance mode,
removal of prior file credentials, and rejection of mixed authentication inputs.
The existing local and S3 API scenarios verify compatibility of profile mode.
Terraform validation checks role/profile declarations without AWS credentials.

Created profiles and their actual IAM policies were checked separately with IAM
Policy Simulator. Results are recorded in
[identity evidence](../evidence/ec2-identity-validation-20261013.md).

These checks do not establish a live EC2/IMDS backup or clean-host recovery.

## References

- [AWS EC2 IAM Roles And Instance Profiles](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/iam-roles-for-amazon-ec2.html)
- [AWS IMDS Options For Container Environments](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-options.html)
- [pgBackRest 2.59.1 S3 Credential Retrieval](https://github.com/pgbackrest/pgbackrest/blob/release/2.59.1/src/storage/s3/storage.c)
