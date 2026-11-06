# Setup

Every way to deploy it, and every option. The short version is in the [README](../README.md).

## Deploy

**Before you start**

1. Turn on StackSets trusted access in the organization, once, from the management account:
   ```bash
   aws cloudformation activate-organizations-access
   ```
2. Make sure your instances are managed by Systems Manager (agent running, and either an instance profile or Default Host Management Configuration). [ssm-access](https://github.com/simar-s2/ssm-access) sets both up.

### Terraform

```hcl
data "aws_organizations_organization" "this" {}

module "patch_manager" {
  source = "git::https://github.com/simar-s2/org-patch-manager.git?ref=v0.1.0"

  target_ids = [data.aws_organizations_organization.this.roots[0].id]   # or OU IDs
  regions    = ["us-east-1", "us-west-2"]
}
```

With the central compliance bucket in the log-archive account:

```hcl
module "compliance_bucket" {
  source    = "git::https://github.com/simar-s2/org-patch-manager.git//modules/compliance-bucket?ref=v0.1.0"
  providers = { aws = aws.log_archive }
}

module "patch_manager" {
  source = "git::https://github.com/simar-s2/org-patch-manager.git?ref=v0.1.0"

  target_ids               = ["ou-ab12-11111111"]
  regions                  = ["us-east-1", "us-west-2"]
  compliance_bucket_name   = module.compliance_bucket.bucket_name
  compliance_bucket_region = module.compliance_bucket.bucket_region
}
```

Full versions: [examples/basic](../examples/basic) and [examples/complete](../examples/complete).

### CloudFormation

```bash
git clone https://github.com/simar-s2/org-patch-manager && cd org-patch-manager
scripts/deploy.sh --profile management --regions us-east-1,us-west-2 \
  --targets r-ab12 --log-archive-profile log-archive
```

This deploys the compliance bucket in the log-archive account, creates the StackSet, and rolls it out to every account under the root. Add `--include-management` to also cover the management account, which service-managed StackSets never deploy to.

### Tag the instances

Instances already running have no `patch-reboot` tag, so they are scanned but not patched. Tag them once per account:

```bash
scripts/default-reboot-tag.sh --profile my-account --regions us-east-1,us-west-2 --dry-run
scripts/default-reboot-tag.sh --profile my-account --regions us-east-1,us-west-2
```

It only tags instances that have no tag yet, and skips EKS nodes and instances tagged `ssm-exempt=true`. Tag hosts that must not reboot on their own with `patch-reboot=never`, and give new instances the tag in their launch template or Terraform.

## Configuration

### Terraform inputs (root module, run in the management account)

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | `string` | `sec` | Prefix for the StackSet, baselines, associations and sync |
| `target_ids` | `list(string)` | `[]` | OU IDs or the root ID. Empty creates the StackSet without deploying it |
| `regions` | `list(string)` | `["us-east-1"]` | Regions to deploy to in each account |
| `call_as` | `string` | `SELF` | `DELEGATED_ADMIN` when running from a StackSets delegated administrator |
| `approve_after_days` | `number` | `7` | Soak period for AL2023 updates |
| `scan_schedule` | `string` | `rate(1 day)` | Compliance scan schedule |
| `install_schedule` | `string` | `cron(0 9 * * ? *)` | Install schedule, UTC |
| `reboot_option` | `string` | `RebootIfNeeded` | For `if-needed` instances. `NoReboot` pauses reboots everywhere |
| `reboot_tag_key` | `string` | `patch-reboot` | The opt-in tag |
| `install_max_concurrency` | `string` | `1` | Instances patched at once per account |
| `install_max_errors` | `string` | `100%` | Failures before an install run stops, per account |
| `compliance_bucket_name` | `string` | `""` | Central bucket for Resource Data Sync. Empty means no sync |
| `compliance_bucket_region` | `string` | `""` | Bucket region. Empty means each stack's region |
| `failure_tolerance_percentage` | `number` | `20` | StackSet failure tolerance per region |
| `deploy_to_management_account` | `bool` | `false` | Also deploy a regular stack in the management account |

### Terraform outputs

| Name | Description |
|---|---|
| `stack_set_name`, `stack_set_id` | The StackSet |
| `deployed_regions` | Regions with a StackSet instance |
| `baseline_names` | Names of the default baselines in every account |
| `reboot_tag` | The opt-in tag key and its values |

### `modules/compliance-bucket` (run in the log-archive account)

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | `string` | `sec` | Used in the default bucket name |
| `bucket_name` | `string` | `null` | Defaults to `<name_prefix>-patch-compliance-<account ID>` |
| `org_id` | `string` | `null` | Organization allowed to write. Looked up when null |
| `retention_days` | `number` | `395` | How long compliance snapshots are kept |

Outputs: `bucket_name`, `bucket_arn`, `bucket_region`.

### CloudFormation parameters

[cloudformation/patch-baseline.yaml](../cloudformation/patch-baseline.yaml) takes the same settings as the Terraform inputs (`NamePrefix`, `ApproveAfterDays`, `ScanSchedule`, `InstallSchedule`, `RebootOption`, `RebootTagKey`, `InstallMaxConcurrency`, `InstallMaxErrors`, `ComplianceBucketName`, `ComplianceBucketRegion`). Pass them to the deploy script with `--param Key=Value`.
