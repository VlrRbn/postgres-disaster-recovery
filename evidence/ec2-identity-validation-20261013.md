# EC2 Workload Identity Validation Evidence

- Result: PASS
- Date: `2026-10-13`
- CI and review: [PR #11](https://github.com/VlrRbn/postgres-disaster-recovery/pull/11)
- Source: working changes on `feat/ec2-workload-identity`, based on `0c2c1f6`
- Environment: Linux amd64, Docker Engine `29.2.0`, Compose `5.0.2`
- PostgreSQL: `17.11`; pgBackRest: `2.59.1`
- Terraform: `1.14.4`; AWS provider: `6.47.0`
- AWS account identifiers: anonymized as `123456789012`

## Validation

Local configuration checks, runtime regression, and Terraform validation passed.
The reviewed AWS plan created six IAM resources, and policy simulation passed
for both identities.

`make check` passed with 26 unit test methods. Instance-mode checks require
`repo1-s3-key-type=auto` and the absence of an access key, secret key, and session
token in the generated config. The CLI prepares it without a bootstrap profile
or any AWS CLI credential request. Switching from a prior profile config removes
the old credential fields while retaining file mode `0600`, and clears saved
profile and role ARN values. Explicit profile/role inputs from environment
variables or CLI arguments are rejected before credential requests or file writes.

Tests reject explicit credentials supplied to instance mode, absent credentials
in profile mode, and unknown authentication modes. Existing repository identity
guards and profile-mode tests still pass.

## Regression

`make acceptance` passed local persistence, backup verification, unsafe-target
and missing-WAL rejection, isolated restore, and PITR. All 22 expected PITR rows
matched exactly and a new recovered-side write survived restart.

`make s3-acceptance` passed the existing profile-mode API fixture, including
versioning, three-full retention, recovery of the oldest retained copy with later
WAL, and a confirmed new write. Both disposable projects removed their resources.

## Terraform Checks

Terraform formatting and validation passed. The exact pinned-container CI command
also passed without AWS credentials. The declarations define EC2-only trust,
prefix-scoped writer access, read-only reader access, and separate instance profiles.
No existing SSO role trust or S3 bucket settings are changed by this code.

## AWS Identities And Permissions

After the bootstrap SSO session was refreshed, AWS confirmed account
`123456789012`. The saved plan contains exactly six creates: writer/reader roles,
their inline policies, and their instance profiles. Existing resources are
unchanged and none are destroyed.

The planned trust documents allow only the EC2 service. Policy inspection
confirmed prefix-scoped access: reader allows only `s3:ListBucket` and
`s3:GetObject`; writer adds put, delete, and multipart operations, without
historical-version deletion.

The saved Terraform plan applied successfully: six resources added,
zero existing resources changed, and zero destroyed. AWS returned these profiles:

- `postgres-dr-ec2-writer`, containing `arn:aws:iam::123456789012:role/postgres-dr-ec2-writer`;
- `postgres-dr-ec2-reader`, containing `arn:aws:iam::123456789012:role/postgres-dr-ec2-reader`.

Independent IAM reads confirmed each profile contains exactly its intended role
and each trust document permits only the EC2 service. IAM Policy Simulator
evaluated the actual attached role policies:

| Operation | Writer | Reader |
| --- | --- | --- |
| List the repository prefix | Allowed | Allowed |
| Get an object in the repository prefix | Allowed | Allowed |
| Put/delete an object in the repository prefix | Allowed | Denied |
| Multipart upload operations in the repository prefix | Allowed | Denied |
| Delete a historical object version | Denied | Denied |
| List/get/put/delete outside the repository prefix | Denied | Denied |

The observation is saved in ignored
`.local/reports/ec2-identity-iam-validation-20261013.json`. Simulation evaluates
authorization without executing the S3 operations. It does not prove live EC2
metadata access or the complete S3 request path.

## Interpretation

The result verifies configuration without stored AWS credentials, provisioned
EC2 identities, and the simulated permissions of the writer and reader roles.
No EC2 instance was created. Actual IMDS authentication and replacement-host
recovery remain unverified until the AWS deployment step. See
[EC2 workload identity](../docs/ec2-workload-identity.md) for configuration,
metadata requirements, and the next deployment step.
