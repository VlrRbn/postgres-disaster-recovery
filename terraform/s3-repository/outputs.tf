output "bucket_name" {
  value = aws_s3_bucket.repository.id
}

output "region" {
  value = var.region
}

output "repository_prefix" {
  value = var.repository_prefix
}

output "writer_role_arn" {
  value = aws_iam_role.writer.arn
}
