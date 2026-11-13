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

output "ec2_instance_profiles" {
  description = "Attach writer to a backup source and reader to a recovery host."
  value = {
    writer = {
      name     = aws_iam_instance_profile.writer.name
      role_arn = aws_iam_role.ec2_writer.arn
    }
    reader = {
      name     = aws_iam_instance_profile.reader.name
      role_arn = aws_iam_role.ec2_reader.arn
    }
  }
}

output "patroni_s3_identities" {
  description = "Optional Patroni roles for profile authentication or attached EC2 instance profiles."
  value = {
    for name, role in aws_iam_role.patroni : name => {
      role_arn         = role.arn
      instance_profile = aws_iam_instance_profile.patroni[name].name
      prefix           = var.patroni_repository_prefix
    }
  }
}
