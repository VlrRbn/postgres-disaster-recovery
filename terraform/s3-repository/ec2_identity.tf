# EC2 workloads receive temporary credentials through their instance profile.
# Keep the existing SSO-assumable writer role for the local development workflow.
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_writer" {
  name               = "${var.ec2_role_name_prefix}-writer"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy" "ec2_writer" {
  name   = "postgres-dr-repository-writer"
  role   = aws_iam_role.ec2_writer.id
  policy = data.aws_iam_policy_document.writer.json
}

resource "aws_iam_instance_profile" "writer" {
  name = "${var.ec2_role_name_prefix}-writer"
  role = aws_iam_role.ec2_writer.name
}

data "aws_iam_policy_document" "reader" {
  statement {
    sid       = "ListRepositoryPrefix"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.repository.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [var.repository_prefix, "${var.repository_prefix}/*"]
    }
  }
  statement {
    sid       = "ReadRepositoryObjects"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.repository.arn}/${var.repository_prefix}/*"]
  }
}

resource "aws_iam_role" "ec2_reader" {
  name               = "${var.ec2_role_name_prefix}-reader"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy" "ec2_reader" {
  name   = "postgres-dr-repository-reader"
  role   = aws_iam_role.ec2_reader.id
  policy = data.aws_iam_policy_document.reader.json
}

resource "aws_iam_instance_profile" "reader" {
  name = "${var.ec2_role_name_prefix}-reader"
  role = aws_iam_role.ec2_reader.name
}
