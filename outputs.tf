output "stack_set_name" {
  description = "Name of the StackSet."
  value       = aws_cloudformation_stack_set.this.name
}

output "stack_set_id" {
  description = "ID of the StackSet."
  value       = aws_cloudformation_stack_set.this.stack_set_id
}

output "deployed_regions" {
  description = "Regions with a StackSet instance. Empty until target_ids is set."
  value       = sort(keys(aws_cloudformation_stack_set_instance.this))
}

output "baseline_names" {
  description = "Names of the default patch baselines created in every account and region."
  value = {
    amazon_linux_2023 = "${var.name_prefix}-al2023"
    ubuntu            = "${var.name_prefix}-ubuntu"
  }
}

output "reboot_tag" {
  description = "The tag that opts instances into installs, and its accepted values."
  value = {
    key    = var.reboot_tag_key
    values = ["if-needed", "never"]
  }
}
