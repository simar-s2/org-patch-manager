# Central bucket for patch compliance. Every account's SSM Resource Data Sync
# (created by the StackSet template) writes its inventory and patch compliance
# here, so the whole fleet can be queried in one place (for example with Athena).
#
# SSE-S3 rather than a KMS key: there are many cross-account writers and the
# data is low-sensitivity operational metadata, so key grants for every
# account's SSM service would add work without adding protection.

data "aws_caller_identity" "current" {}

data "aws_organizations_organization" "this" {
  count = var.org_id == null ? 1 : 0
}

locals {
  bucket_name = coalesce(var.bucket_name, "${var.name_prefix}-patch-compliance-${data.aws_caller_identity.current.account_id}")
  org_id      = var.org_id != null ? var.org_id : data.aws_organizations_organization.this[0].id
}

resource "aws_s3_bucket" "this" {
  #checkov:skip=CKV_AWS_145:SSE-S3 by design, see the note at the top of this file.
  #checkov:skip=CKV_AWS_18:Operational metadata written only by the SSM service; access logs would cost more than they reveal.
  #checkov:skip=CKV_AWS_144:A second copy of regenerable compliance data is not worth the replication cost.
  #checkov:skip=CKV2_AWS_62:Nothing consumes object events; the data is queried on demand.
  bucket = local.bucket_name
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-compliance-data"
    status = "Enabled"
    filter {}

    expiration {
      days = var.retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Only the SSM service, acting for an account in this organization, may write.
data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "SSMBucketAcl"
    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [aws_s3_bucket.this.arn]
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceOrgID"
      values   = [local.org_id]
    }
  }

  statement {
    sid       = "SSMBucketDelivery"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceOrgID"
      values   = [local.org_id]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}
