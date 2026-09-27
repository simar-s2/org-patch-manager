# Central compliance bucket in the log-archive account, and the StackSet from
# the management account deploying to two OUs, with weekday-only installs and a
# shorter soak.

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "log_archive_account_id" {
  type        = string
  description = "Account ID of the log-archive account."
}

variable "target_ou_ids" {
  type        = list(string)
  description = "OUs whose accounts get the patch configuration."
}

provider "aws" {
  alias  = "management"
  region = "us-east-1"
}

provider "aws" {
  alias  = "log_archive"
  region = "us-east-1"

  assume_role {
    role_arn = "arn:aws:iam::${var.log_archive_account_id}:role/OrganizationAccountAccessRole"
  }
}

module "compliance_bucket" {
  source    = "../../modules/compliance-bucket"
  providers = { aws = aws.log_archive }

  name_prefix = "acme"
}

module "patch_manager" {
  source    = "../.."
  providers = { aws = aws.management }

  name_prefix = "acme"
  target_ids  = var.target_ou_ids
  regions     = ["us-east-1", "us-west-2"]

  approve_after_days = 3
  install_schedule   = "cron(0 10 ? * MON-FRI *)"

  compliance_bucket_name   = module.compliance_bucket.bucket_name
  compliance_bucket_region = module.compliance_bucket.bucket_region
}

output "compliance_bucket" {
  value = module.compliance_bucket.bucket_name
}

output "baseline_names" {
  value = module.patch_manager.baseline_names
}
