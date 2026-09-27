variable "name_prefix" {
  type        = string
  description = "Prefix for the StackSet and for the baselines, associations and sync it creates in each account."
  default     = "sec"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "Use 1-20 lowercase letters, digits or hyphens."
  }
}

variable "target_ids" {
  type        = list(string)
  description = "OU IDs (ou-...) or the root ID (r-...) to deploy to. Every account under them, now or later, is enrolled. Empty creates the StackSet without deploying it."
  default     = []

  validation {
    condition     = alltrue([for id in var.target_ids : can(regex("^(ou-[0-9a-z]{4,32}-[0-9a-z]{8,32}|r-[0-9a-z]{4,32})$", id))])
    error_message = "Each target must be an OU ID (ou-xxxx-xxxxxxxx) or a root ID (r-xxxx)."
  }
}

variable "regions" {
  type        = list(string)
  description = "Regions to deploy the patch configuration to in each account."
  default     = ["us-east-1"]
}

variable "call_as" {
  type        = string
  description = "SELF when running from the management account, DELEGATED_ADMIN from a StackSets delegated administrator."
  default     = "SELF"

  validation {
    condition     = contains(["SELF", "DELEGATED_ADMIN"], var.call_as)
    error_message = "Use SELF or DELEGATED_ADMIN."
  }
}

variable "approve_after_days" {
  type        = number
  description = "Days an AL2023 security or bugfix update soaks before it is auto-approved. Ubuntu has no soak period."
  default     = 7

  validation {
    condition     = var.approve_after_days >= 0 && var.approve_after_days <= 360
    error_message = "Use 0-360 days."
  }
}

variable "scan_schedule" {
  type        = string
  description = "Schedule of the read-only compliance scan on every managed instance."
  default     = "rate(1 day)"
}

variable "install_schedule" {
  type        = string
  description = "Schedule of the install runs, in UTC."
  default     = "cron(0 9 * * ? *)"

  validation {
    condition     = can(regex("^(cron|rate)\\(.+\\)$", var.install_schedule))
    error_message = "Use a cron(...) or rate(...) expression."
  }
}

variable "reboot_option" {
  type        = string
  description = "Reboot behaviour for instances tagged <reboot_tag_key>=if-needed. NoReboot pauses reboots everywhere."
  default     = "RebootIfNeeded"

  validation {
    condition     = contains(["RebootIfNeeded", "NoReboot"], var.reboot_option)
    error_message = "Use RebootIfNeeded or NoReboot."
  }
}

variable "reboot_tag_key" {
  type        = string
  description = "Tag that opts an instance into installs: if-needed or never. Untagged instances are scanned only."
  default     = "patch-reboot"
}

variable "install_max_concurrency" {
  type        = string
  description = "Instances patched at the same time in each account."
  default     = "1"
}

variable "install_max_errors" {
  type        = string
  description = "Failures before an install run stops, per account. 100% keeps one host that cannot install from blocking every host after it."
  default     = "100%"
}

variable "compliance_bucket_name" {
  type        = string
  description = "Central S3 bucket (see modules/compliance-bucket) that every account syncs its patch compliance to. Empty means no sync."
  default     = ""
}

variable "compliance_bucket_region" {
  type        = string
  description = "Region of the compliance bucket. Empty means the region of each stack."
  default     = ""
}

variable "failure_tolerance_percentage" {
  type        = number
  description = "Percentage of accounts per region that may fail before the StackSet operation stops."
  default     = 20
}

variable "deploy_to_management_account" {
  type        = bool
  description = "Also deploy the template as a regular stack in the account running Terraform. Service-managed StackSets never deploy to the management account."
  default     = false
}
