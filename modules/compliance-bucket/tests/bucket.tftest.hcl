mock_provider "aws" {
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "444455556666" }
  }
  override_data {
    target = data.aws_organizations_organization.this
    values = { id = "o-exampleorgid" }
  }
}

run "default_name_includes_account_id" {
  command = plan

  assert {
    condition     = aws_s3_bucket.this.bucket == "sec-patch-compliance-444455556666"
    error_message = "Default bucket name is <prefix>-patch-compliance-<account ID>."
  }
  assert {
    condition     = local.org_id == "o-exampleorgid"
    error_message = "Organization ID is looked up when not given."
  }
}

run "explicit_org_id_skips_lookup" {
  command = plan

  variables {
    org_id      = "o-givenorgid"
    bucket_name = "my-patch-compliance"
  }

  assert {
    condition     = length(data.aws_organizations_organization.this) == 0 && local.org_id == "o-givenorgid"
    error_message = "An explicit org_id is used without calling Organizations."
  }
  assert {
    condition     = aws_s3_bucket.this.bucket == "my-patch-compliance"
    error_message = "bucket_name overrides the default."
  }
}
