terraform {
  required_version = "~> 1.14.0"

  backend "local" {
    path = "../../.local/terraform/s3-repository.tfstate"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.47.0"
    }
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = "postgres-disaster-recovery"
      ManagedBy = "Terraform"
    }
  }
}
