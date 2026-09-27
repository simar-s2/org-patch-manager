#!/usr/bin/env bash
# Tag existing instances that have no reboot tag yet, so the nightly install
# covers them. Instances that already have the tag keep their value.
#
# Skipped on purpose:
#   ssm-exempt=true      short-lived hosts (build agents, for example) kept out of
#                        SSM on purpose; keep their base image current instead
#   eks:cluster-name=*   EKS nodes: the EKS-optimized AMI pins the kernel and
#                        container runtime, so in-place installs fail. Roll the
#                        node group (or let Karpenter drift) to a newer AMI instead
#
# New instances should get the tag from their launch template or Terraform.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/default-reboot-tag.sh [options]

  -p, --profile NAME   AWS CLI profile (default: the current credentials)
  -r, --regions LIST   comma-separated regions, or "all" (default: the profile's region)
      --tag-key KEY    reboot tag key (default: patch-reboot)
      --value VALUE    value to set: if-needed (default) or never
      --dry-run        list the instances without tagging them
  -h, --help
USAGE
}

PROFILE="" REGIONS="" TAG_KEY=patch-reboot VALUE=if-needed DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--profile) PROFILE="${2:?}"; shift ;;
    -r|--regions) REGIONS="${2:?}"; shift ;;
    --tag-key) TAG_KEY="${2:?}"; shift ;;
    --value) VALUE="${2:?}"; shift ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
case "$VALUE" in
  if-needed|never) ;;
  *) echo "--value must be if-needed or never" >&2; exit 2 ;;
esac

aws_() {
  if [ -n "$PROFILE" ]; then aws --profile "$PROFILE" "$@"; else aws "$@"; fi
}

if [ -z "$REGIONS" ]; then
  REGIONS="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws_ configure get region || true)}}"
  [ -n "$REGIONS" ] || { echo "no region configured; pass --regions" >&2; exit 2; }
elif [ "$REGIONS" = "all" ]; then
  REGIONS=$(aws_ ec2 describe-regions --region "${AWS_REGION:-us-east-1}" \
    --query 'Regions[].RegionName' --output text | tr '\t' ',')
fi
IFS=',' read -r -a REGION_LIST <<<"$REGIONS"

QUERY="Reservations[].Instances[?!(Tags[?Key=='$TAG_KEY']) && !(Tags[?Key=='ssm-exempt' && Value=='true']) && !(Tags[?Key=='eks:cluster-name'])].InstanceId"

for REGION in "${REGION_LIST[@]}"; do
  read -r -a IDS <<<"$(aws_ ec2 describe-instances --region "$REGION" \
    --filters "Name=instance-state-name,Values=running,stopped" \
    --query "$QUERY" --output text | tr -s '\t\n' '  ')"
  if [ "${#IDS[@]}" -eq 0 ]; then
    printf '%-12s all instances already classified or exempt\n' "$REGION"
    continue
  fi
  if $DRY_RUN; then
    printf '%-12s would tag %d instance(s) %s=%s: %s\n' "$REGION" "${#IDS[@]}" "$TAG_KEY" "$VALUE" "${IDS[*]}"
    continue
  fi
  # CreateTags takes a limited number of resources per call.
  for ((i = 0; i < ${#IDS[@]}; i += 200)); do
    aws_ ec2 create-tags --region "$REGION" --resources "${IDS[@]:i:200}" \
      --tags "Key=$TAG_KEY,Value=$VALUE"
  done
  printf '%-12s tagged %d instance(s) %s=%s\n' "$REGION" "${#IDS[@]}" "$TAG_KEY" "$VALUE"
done
