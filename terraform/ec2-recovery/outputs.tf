output "instance_id" {
  description = "Target for SSM Session Manager and Run Command."
  value       = aws_instance.recovery.id
}

output "ami_id" {
  description = "Canonical Ubuntu AMI selected for this deployment."
  value       = aws_instance.recovery.ami
}

output "reader_role_arn" {
  value = data.aws_iam_instance_profile.reader.role_arn
}
