variable "account_id" {
  description = "Expected AWS account; the provider refuses other accounts."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Use a 12-digit AWS account ID."
  }
}

variable "region" {
  description = "AWS region for the repository bucket."
  type        = string
  default     = "eu-west-1"
}

variable "bucket_name" {
  description = "Globally unique name of a new dedicated repository bucket."
  type        = string
}

variable "repository_prefix" {
  description = "Object prefix reserved for the orders repository."
  type        = string
  default     = "postgres-dr/orders"
  validation {
    condition     = can(regex("^postgres-dr/[a-z0-9]([a-z0-9/-]*[a-z0-9])?$", var.repository_prefix)) && !strcontains(var.repository_prefix, "//")
    error_message = "Use a postgres-dr/ prefix without trailing or repeated slashes."
  }
}

variable "trusted_principal_arn" {
  description = "IAM principal allowed to assume the repository writer role."
  type        = string
}

variable "writer_role_name" {
  description = "Name of the dedicated repository writer role."
  type        = string
  default     = "postgres-dr-s3-writer"
}
