output "bucket_name" {
  description = "Name of the compliance bucket. Pass it to the root module's compliance_bucket_name."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "ARN of the compliance bucket."
  value       = aws_s3_bucket.this.arn
}

output "bucket_region" {
  description = "Region of the compliance bucket. Pass it to compliance_bucket_region."
  value       = aws_s3_bucket.this.region
}
