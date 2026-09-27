variable "name_prefix" {
  type        = string
  description = "Prefix for the bucket name."
  default     = "sec"
}

variable "bucket_name" {
  type        = string
  description = "Bucket name. Null means <name_prefix>-patch-compliance-<account ID>."
  default     = null
}

variable "org_id" {
  type        = string
  description = "AWS Organizations ID (o-...) whose accounts may write. Null looks it up, which works from any account in the organization."
  default     = null
}

variable "retention_days" {
  type        = number
  description = "Days to keep compliance snapshots. The default keeps a year of history plus a month for year-over-year comparisons."
  default     = 395
}
