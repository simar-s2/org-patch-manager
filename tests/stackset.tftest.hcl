mock_provider "aws" {}

run "no_targets_creates_only_the_stack_set" {
  command = plan

  assert {
    condition     = aws_cloudformation_stack_set.this.name == "sec-patch-manager"
    error_message = "StackSet name comes from name_prefix."
  }
  assert {
    condition     = length(aws_cloudformation_stack_set_instance.this) == 0
    error_message = "Nothing is deployed until target_ids is set."
  }
  assert {
    condition     = aws_cloudformation_stack_set.this.auto_deployment[0].enabled
    error_message = "Accounts that join a target OU later must be enrolled automatically."
  }
}

run "one_instance_per_region" {
  command = plan

  variables {
    name_prefix = "acme"
    target_ids  = ["r-ab12", "ou-ab12-11111111"]
    regions     = ["us-east-1", "eu-west-1"]
  }

  assert {
    condition     = toset(keys(aws_cloudformation_stack_set_instance.this)) == toset(["us-east-1", "eu-west-1"])
    error_message = "Expected one StackSet instance per region."
  }
  assert {
    condition     = aws_cloudformation_stack_set_instance.this["eu-west-1"].deployment_targets[0].organizational_unit_ids == toset(["r-ab12", "ou-ab12-11111111"])
    error_message = "Every instance targets every OU."
  }
  assert {
    condition     = aws_cloudformation_stack_set.this.parameters["NamePrefix"] == "acme"
    error_message = "name_prefix is passed to the template."
  }
}

run "safe_install_defaults" {
  command = plan

  assert {
    condition     = aws_cloudformation_stack_set.this.parameters["InstallMaxErrors"] == "100%"
    error_message = "One failing host must not stop the run for the rest of the account."
  }
  assert {
    condition     = aws_cloudformation_stack_set.this.parameters["ComplianceBucketName"] == ""
    error_message = "The compliance sync is off unless a bucket is given."
  }
}

run "management_account_stacks" {
  command = plan

  variables {
    regions                      = ["us-east-1", "us-west-2"]
    deploy_to_management_account = true
  }

  assert {
    condition     = length(aws_cloudformation_stack.management) == 2
    error_message = "One regular stack per region in the management account."
  }
}

run "rejects_bad_targets" {
  command = plan

  variables {
    target_ids = ["111122223333"]
  }

  expect_failures = [var.target_ids]
}

run "rejects_bad_reboot_option" {
  command = plan

  variables {
    reboot_option = "Always"
  }

  expect_failures = [var.reboot_option]
}
