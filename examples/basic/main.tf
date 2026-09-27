# Deploy the patch configuration to every account in the organization, in two
# regions. Run from the management account.

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_organizations_organization" "this" {}

module "patch_manager" {
  source = "../.."

  target_ids = [data.aws_organizations_organization.this.roots[0].id]
  regions    = ["us-east-1", "us-west-2"]
}

output "stack_set_name" {
  value = module.patch_manager.stack_set_name
}
