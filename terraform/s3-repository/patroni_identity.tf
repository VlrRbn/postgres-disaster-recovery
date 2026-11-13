# Opt in without widening the existing standalone repository policies.
locals {
  patroni_identities = var.patroni_repository_prefix == null ? toset([]) : toset(["writer", "reader"])
}

data "aws_iam_policy_document" "patroni_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [var.trusted_principal_arn]
    }
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "patroni" {
  for_each = local.patroni_identities
  statement {
    sid       = "ListPatroniPrefix"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.repository.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [var.patroni_repository_prefix, "${var.patroni_repository_prefix}/*"]
    }
  }
  statement {
    sid = "PatroniRepositoryObjects"
    actions = each.key == "reader" ? ["s3:GetObject"] : [
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
      "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"
    ]
    resources = ["${aws_s3_bucket.repository.arn}/${var.patroni_repository_prefix}/*"]
  }
}

resource "aws_iam_role" "patroni" {
  for_each             = local.patroni_identities
  name                 = "${var.patroni_role_name_prefix}-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.patroni_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "patroni" {
  for_each = local.patroni_identities
  name     = "postgres-dr-patroni-prefix"
  role     = aws_iam_role.patroni[each.key].id
  policy   = data.aws_iam_policy_document.patroni[each.key].json
}

resource "aws_iam_instance_profile" "patroni" {
  for_each = local.patroni_identities
  name     = "${var.patroni_role_name_prefix}-${each.key}"
  role     = aws_iam_role.patroni[each.key].name
}
