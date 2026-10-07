resource "aws_s3_bucket" "repository" {
  bucket        = var.bucket_name
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "repository" {
  bucket                  = aws_s3_bucket.repository.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "repository" {
  bucket = aws_s3_bucket.repository.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "repository" {
  bucket = aws_s3_bucket.repository.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "repository" {
  bucket = aws_s3_bucket.repository.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "transport" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.repository.arn, "${aws_s3_bucket.repository.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "transport" {
  bucket = aws_s3_bucket.repository.id
  policy = data.aws_iam_policy_document.transport.json
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [var.trusted_principal_arn]
    }
  }
}

resource "aws_iam_role" "writer" {
  name                 = var.writer_role_name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "writer" {
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
    sid = "ReadWriteRepositoryObjects"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
      "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"
    ]
    resources = ["${aws_s3_bucket.repository.arn}/${var.repository_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "writer" {
  name   = "postgres-dr-repository-prefix"
  role   = aws_iam_role.writer.id
  policy = data.aws_iam_policy_document.writer.json
}
