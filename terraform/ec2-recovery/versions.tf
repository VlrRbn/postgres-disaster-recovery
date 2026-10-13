terraform {
  required_version = "~> 1.14.0"

  backend "local" {
    path = "../../.local/terraform/ec2-recovery.tfstate"
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
      Purpose   = "temporary-clean-host-recovery"
    }
  }
}
