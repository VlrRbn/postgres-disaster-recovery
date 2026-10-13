variable "account_id" {
  description = "Expected AWS account; the provider refuses other accounts."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Use a 12-digit AWS account ID."
  }
}

variable "region" {
  description = "Region containing the existing reader instance profile and S3 repository."
  type        = string
  default     = "eu-west-1"
}

variable "ec2_role_name_prefix" {
  description = "Prefix of the reader role and profile created by s3-repository."
  type        = string
  default     = "postgres-dr-ec2"
  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,50}$", var.ec2_role_name_prefix))
    error_message = "Use a valid IAM name prefix of at most 50 characters."
  }
}

variable "instance_type" {
  description = "Temporary x86_64 recovery host; match the Docker image architecture."
  type        = string
  default     = "t3.small"
  validation {
    condition     = contains(["t3.small", "t3.medium"], var.instance_type)
    error_message = "Use t3.small or t3.medium for this x86_64 lab."
  }
}
