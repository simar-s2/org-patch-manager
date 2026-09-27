#!/usr/bin/env bash
# Deploy org-patch-manager with CloudFormation only.
#
#   1. (optional) the compliance bucket stack in the log-archive account
#   2. the service-managed StackSet, from the management account or a
#      StackSets delegated administrator
#   3. StackSet instances for the target OUs / root in each region
#   4. (optional) a regular stack in the management account, which
#      service-managed StackSets never deploy to
#
# Needs StackSets trusted access in the organization, once:
#   aws cloudformation activate-organizations-access
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/deploy.sh --regions LIST [options]

  -r, --regions LIST             regions to deploy to in each account
      --targets IDS              comma-separated OU IDs or the root ID (r-xxxx);
                                 without it the StackSet is created but not deployed
  -p, --profile NAME             management account (or StackSets delegated admin)
      --delegated-admin          call StackSets as a delegated administrator
      --prefix NAME              name prefix (default: sec)
      --log-archive-profile NAME deploy the compliance bucket in this account first
                                 and sync every account's patch compliance to it
      --compliance-bucket NAME   sync to an existing bucket instead
      --include-management       also deploy a regular stack in the management account
      --param KEY=VALUE          template parameter, repeatable
                                 (e.g. --param ApproveAfterDays=3)
  -h, --help
USAGE
}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REGIONS="" TARGETS="" PROFILE="" CALL_AS=SELF PREFIX=sec
LOG_ARCHIVE_PROFILE="" BUCKET="" BUCKET_REGION="" INCLUDE_MANAGEMENT=false PARAMS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--regions) REGIONS="${2:?}"; shift ;;
    --targets) TARGETS="${2:?}"; shift ;;
    -p|--profile) PROFILE="${2:?}"; shift ;;
    --delegated-admin) CALL_AS=DELEGATED_ADMIN ;;
    --prefix) PREFIX="${2:?}"; shift ;;
    --log-archive-profile) LOG_ARCHIVE_PROFILE="${2:?}"; shift ;;
    --compliance-bucket) BUCKET="${2:?}"; shift ;;
    --include-management) INCLUDE_MANAGEMENT=true ;;
    --param) PARAMS+=("${2:?}"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$REGIONS" ] || { usage >&2; exit 2; }

aws_() {
  if [ -n "$PROFILE" ]; then aws --profile "$PROFILE" "$@"; else aws "$@"; fi
}

IFS=',' read -r -a REGION_LIST <<<"$REGIONS"
HOME_REGION=${REGION_LIST[0]}
NAME="$PREFIX-patch-manager"

# ---- 1. compliance bucket
if [ -n "$LOG_ARCHIVE_PROFILE" ]; then
  ORG_ID=$(aws_ organizations describe-organization --query Organization.Id --output text)
  echo "== compliance bucket stack in the log-archive account ($HOME_REGION)"
  aws --profile "$LOG_ARCHIVE_PROFILE" cloudformation deploy --region "$HOME_REGION" \
    --stack-name "$PREFIX-patch-compliance-bucket" \
    --template-file "$ROOT/cloudformation/compliance-bucket.yaml" \
    --no-fail-on-empty-changeset \
    --parameter-overrides "NamePrefix=$PREFIX" "OrgId=$ORG_ID" ${BUCKET:+"BucketName=$BUCKET"}
  BUCKET=$(aws --profile "$LOG_ARCHIVE_PROFILE" cloudformation describe-stacks --region "$HOME_REGION" \
    --stack-name "$PREFIX-patch-compliance-bucket" \
    --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text)
  BUCKET_REGION=$HOME_REGION
  echo "   bucket: $BUCKET"
fi

PARAMS=("NamePrefix=$PREFIX" "ComplianceBucketName=$BUCKET" "ComplianceBucketRegion=$BUCKET_REGION"
  ${PARAMS[@]+"${PARAMS[@]}"})
CFN_PARAMS=()
for P in "${PARAMS[@]}"; do
  CFN_PARAMS+=("ParameterKey=${P%%=*},ParameterValue=${P#*=}")
done

# ---- 2. StackSet
stackset() { # stackset SUBCOMMAND ARGS...
  local cmd=$1
  shift
  aws_ cloudformation "$cmd" --region "$HOME_REGION" --stack-set-name "$NAME" --call-as "$CALL_AS" "$@"
}

wait_for() { # wait_for OPERATION_ID
  local status
  while true; do
    status=$(stackset describe-stack-set-operation --operation-id "$1" \
      --query StackSetOperation.Status --output text)
    case "$status" in
      SUCCEEDED) echo "   $status"; return 0 ;;
      FAILED|STOPPED) echo "   $status: see 'aws cloudformation list-stack-set-operation-results'" >&2; return 1 ;;
    esac
    sleep 15
  done
}

if stackset describe-stack-set >/dev/null 2>&1; then
  echo "== updating StackSet $NAME"
  OP=$(stackset update-stack-set --template-body "file://$ROOT/cloudformation/patch-baseline.yaml" \
    --capabilities CAPABILITY_IAM --parameters "${CFN_PARAMS[@]}" --query OperationId --output text)
  wait_for "$OP"
else
  echo "== creating StackSet $NAME"
  stackset create-stack-set --template-body "file://$ROOT/cloudformation/patch-baseline.yaml" \
    --capabilities CAPABILITY_IAM --permission-model SERVICE_MANAGED \
    --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
    --parameters "${CFN_PARAMS[@]}" >/dev/null
fi

# ---- 3. instances (safe to repeat: existing instances are kept)
if [ -n "$TARGETS" ]; then
  echo "== deploying to $TARGETS in ${REGION_LIST[*]}"
  OP=$(stackset create-stack-instances --deployment-targets "OrganizationalUnitIds=$TARGETS" \
    --regions "${REGION_LIST[@]}" \
    --operation-preferences RegionConcurrencyType=PARALLEL,MaxConcurrentPercentage=100,FailureTolerancePercentage=20 \
    --query OperationId --output text)
  wait_for "$OP"
else
  echo "== no --targets: StackSet created, nothing deployed yet"
fi

# ---- 4. management account
if $INCLUDE_MANAGEMENT; then
  for REGION in "${REGION_LIST[@]}"; do
    echo "== stack $NAME in the management account ($REGION)"
    aws_ cloudformation deploy --region "$REGION" --stack-name "$NAME" \
      --template-file "$ROOT/cloudformation/patch-baseline.yaml" --capabilities CAPABILITY_IAM \
      --no-fail-on-empty-changeset --parameter-overrides "${PARAMS[@]}"
  done
fi
