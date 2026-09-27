# org-patch-manager

**Org-wide EC2 patching with AWS Systems Manager Patch Manager: one StackSet enrolls every account in an OU or the whole organization, including accounts that join later, and a tag decides whether an instance may reboot.**

Part of [aws-security-toolkit](https://github.com/simar-s2/aws-security-toolkit).

![terraform test and a reboot-tag dry run](docs/images/demo.gif)

*`make demo`: the Terraform tests against a mocked AWS provider, then the tagging script against the fake AWS CLI used by the tests. Neither needs an AWS account.*

## What it does

A service-managed CloudFormation StackSet deploys one template into every account under the target OUs (or the organization root), in each region you choose. In every account it:

- **Creates two patch baselines and makes them the OS defaults.** Amazon Linux 2023 gets security and bugfix updates after a 7-day soak; Ubuntu gets required, important and standard updates. Because they are the defaults, they apply to every instance of that OS with no Patch Group tags to maintain. Other operating systems keep using the AWS default baseline.
- **Scans every managed instance daily.** A read-only scan that never reboots, so compliance is always current and shows up in Security Hub as control SSM.2.
- **Installs nightly on instances that opted in with a tag.** The `patch-reboot` tag decides whether an instance may reboot after patching. Untagged instances are scanned but never patched automatically.
- **Exports patch compliance to one central bucket** (optional). Each account's SSM Resource Data Sync writes to an S3 bucket in the log-archive account, so the whole fleet can be queried in one place.

New accounts are enrolled automatically when they join a target OU, and the stacks are removed when they leave.

| `patch-reboot` tag | Scanned daily | Patched nightly | Reboots |
|---|:-:|:-:|---|
| `if-needed` | yes | yes | when an update needs it |
| `never` | yes | yes | never; kernel updates wait for an operator-chosen reboot |
| *(no tag)* | yes | no | no |

**Tech:** Terraform (AWS provider 6), CloudFormation StackSets, AWS Systems Manager (Patch Manager, State Manager, Resource Data Sync), a Python custom resource, Bash, pytest, GitHub Actions.

## Architecture

```mermaid
flowchart TB
    subgraph mgmt["Management account (or StackSets delegated admin)"]
        stackset["StackSet<br/>service-managed, auto-deploy"]
    end

    subgraph member["Every account under the target OUs, in each region"]
        direction TB
        baselines["AL2023 + Ubuntu baselines"]
        cr["Custom resource<br/>registers them as OS defaults"]
        scan["Scan association<br/>all instances, daily"]
        install["Install associations<br/>tag:patch-reboot = if-needed / never"]
        sync["Resource Data Sync"]
        ec2[("EC2 instances<br/>(SSM-managed)")]
        cr --> baselines
        scan --> ec2
        install --> ec2
        ec2 -. "compliance" .-> sync
    end

    subgraph logs["Log-archive account"]
        bucket[("Compliance bucket<br/>SSE-S3, org-only writes")]
    end

    hub["Security Hub<br/>SSM.2 compliance, SSM.3 failed runs"]

    stackset -->|"deploys and auto-enrolls"| member
    sync -->|"ssm.amazonaws.com,<br/>aws:SourceOrgID"| bucket
    ec2 -. "findings" .-> hub
```

## Quick start

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

Full versions: [examples/basic](examples/basic) and [examples/complete](examples/complete).

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

[cloudformation/patch-baseline.yaml](cloudformation/patch-baseline.yaml) takes the same settings as the Terraform inputs (`NamePrefix`, `ApproveAfterDays`, `ScanSchedule`, `InstallSchedule`, `RebootOption`, `RebootTagKey`, `InstallMaxConcurrency`, `InstallMaxErrors`, `ComplianceBucketName`, `ComplianceBucketRegion`). Pass them to the deploy script with `--param Key=Value`.

## Cost

Patch Manager, State Manager and Resource Data Sync have no extra charge for EC2 instances. What you pay for:

- **S3** storage for the compliance export: a few KB per instance per day, expired after 395 days.
- **Lambda**: the custom resource runs only when a stack is created, updated or deleted, well inside the free tier.
- **Data transfer**: instances download updates through a NAT gateway or VPC endpoints, which are billed as usual.
- **Security Hub** bills for the SSM.2 and SSM.3 control checks if you have it on (see [org-security-baseline](https://github.com/simar-s2/org-security-baseline#cost)).

## Design notes

- **Default baselines instead of Patch Groups.** Registering the baselines as the OS defaults covers every instance with no tagging. CloudFormation has no resource for that, so a small custom resource calls `RegisterDefaultPatchBaseline`. On delete it reverts to the AWS baseline only if ours is still the default, so replacing a baseline during an update doesn't leave the account on the AWS default.
- **Scan everything, install only what opted in.** A host nobody has looked at yet should never be rebooted by a patch run. Untagged instances are visible as non-compliant, which prompts someone to classify them.
- **Two install associations.** State Manager targets are include-only (there's no "exclude"), so the no-reboot carve-out needs its own association.
- **`ApplyOnlyAtCronInterval` on the install associations.** Without it, State Manager runs a new association right away, which would patch and reboot every tagged instance the moment the StackSet deploys.
- **`MaxErrors` of 100%.** With a low limit, one host that can never install (for example an image with pinned packages) stops the run, and every host after it in that account is skipped every night.
- **Nightly installs.** The daily scan finds missing patches within a day; a weekly install window would leave approved patches unapplied for up to six more days.
- **EKS nodes are replaced, not patched.** The EKS-optimized AMI pins the kernel and container runtime, so in-place installs fail. Update the node group AMI (or let Karpenter drift) instead; the tagging script skips these nodes.
- **`never` for hosts with custom drivers.** GPU hosts and appliances with kernel modules (for example DKMS drivers) need the module rebuilt for a new kernel, so the reboot should happen when an operator can check it.
- **Short-lived hosts are exempt.** A build agent that lives a few hours never completes a patch-and-reboot cycle; keep its base image current and tag it `ssm-exempt=true`.
- **No soak period for Ubuntu.** APT repositories don't provide reliable release dates, so Ubuntu updates are approved immediately.
- **SSE-S3 on the compliance bucket.** Many cross-account writers and low-sensitivity data: a KMS key would need grants for every account's SSM service without adding real protection.
- **Watch SSM.3, not just SSM.2.** A failed patch run shows up in Security Hub as SSM.3, which is LOW severity and easy to miss in a CRITICAL/HIGH view. [security-digest](https://github.com/simar-s2/security-digest) rolls SSM.2 and SSM.3 up per account in its daily Slack message.

## Project layout

```
main.tf, variables.tf, ...        root module: the StackSet (management account)
modules/compliance-bucket/        central compliance bucket (log-archive account)
cloudformation/patch-baseline.yaml  the member-account template, used by both deploy paths
cloudformation/compliance-bucket.yaml
scripts/deploy.sh                 one-command CloudFormation deploy
scripts/default-reboot-tag.sh     tag existing instances
examples/                         Terraform examples
tests/                            pytest (custom resource, scripts) and terraform test
```

## Development

```bash
make test    # pytest and terraform test; nothing calls AWS
make lint    # terraform fmt/validate, tflint, cfn-lint, checkov, shellcheck
make demo    # the recording above
```

The custom resource tests load the function source directly from the CloudFormation template, so they test exactly what gets deployed.

## License

[MIT](LICENSE)
