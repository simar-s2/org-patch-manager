locals {
  template = file("${path.module}/cloudformation/patch-baseline.yaml")

  parameters = {
    NamePrefix             = var.name_prefix
    ApproveAfterDays       = tostring(var.approve_after_days)
    ScanSchedule           = var.scan_schedule
    InstallSchedule        = var.install_schedule
    RebootOption           = var.reboot_option
    RebootTagKey           = var.reboot_tag_key
    InstallMaxConcurrency  = var.install_max_concurrency
    InstallMaxErrors       = var.install_max_errors
    ComplianceBucketName   = var.compliance_bucket_name
    ComplianceBucketRegion = var.compliance_bucket_region
  }
}

# A service-managed StackSet deploys cloudformation/patch-baseline.yaml into
# every account under var.target_ids. Auto-deployment enrolls accounts that
# join those OUs later and removes the stacks from accounts that leave.
resource "aws_cloudformation_stack_set" "this" {
  name             = "${var.name_prefix}-patch-manager"
  description      = "Org-wide SSM Patch Manager: AL2023 and Ubuntu default baselines, daily scan, tag-driven nightly install."
  permission_model = "SERVICE_MANAGED"
  capabilities     = ["CAPABILITY_IAM"]
  call_as          = var.call_as
  template_body    = local.template
  parameters       = local.parameters

  auto_deployment {
    enabled                          = true
    retain_stacks_on_account_removal = false
  }

  lifecycle {
    # Set by AWS for service-managed StackSets; would otherwise show a diff on every plan.
    ignore_changes = [administration_role_arn]
  }
}

# One instance per region, each covering every account under the targets.
resource "aws_cloudformation_stack_set_instance" "this" {
  for_each = length(var.target_ids) > 0 ? toset(var.regions) : toset([])

  stack_set_name            = aws_cloudformation_stack_set.this.name
  stack_set_instance_region = each.key
  call_as                   = var.call_as

  deployment_targets {
    organizational_unit_ids = var.target_ids
  }

  operation_preferences {
    max_concurrent_percentage    = 100
    failure_tolerance_percentage = var.failure_tolerance_percentage
    region_concurrency_type      = "PARALLEL"
  }
}

resource "aws_cloudformation_stack" "management" {
  #checkov:skip=CKV_AWS_124:Deployed and watched by Terraform, which reports stack failures itself.
  for_each = var.deploy_to_management_account ? toset(var.regions) : toset([])
  region   = each.key

  name          = "${var.name_prefix}-patch-manager"
  template_body = local.template
  parameters    = local.parameters
  capabilities  = ["CAPABILITY_IAM"]
}
