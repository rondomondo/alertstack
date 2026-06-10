#!/usr/bin/env bash
# One-time setup: create S3 state and deploy buckets, upload redeploy.sh.
# Run ONCE before `tofu init` and `tofu apply`.
# Usage: ./scripts/bootstrap.sh [--profile <aws-profile>] [--region <region>]
set -euo pipefail

REGION="us-east-1"
AWS_PROFILE="${AWS_PROFILE:-limitedsuperpowers}"
STATE_BUCKET="alertstack-tofu-state"
DEPLOY_BUCKET="alertstack-deploy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case $1 in
    --profile) AWS_PROFILE="$2"; shift 2 ;;
    --region)  REGION="$2";      shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

export AWS_PROFILE

aws_cmd() { aws --output text --region "$REGION" "$@"; }

echo "==> Using AWS profile: $AWS_PROFILE"
echo "    Region:             $REGION"
echo ""

create_bucket() {
  local bucket="$1"
  if aws_cmd s3api head-bucket --bucket "$bucket" &>/dev/null; then
    echo "==> Bucket already exists: s3://$bucket"
    return
  fi

  echo "==> Creating bucket: s3://$bucket"
  if [[ "$REGION" == "us-east-1" ]]; then
    aws_cmd s3api create-bucket --bucket "$bucket"
  else
    aws_cmd s3api create-bucket --bucket "$bucket" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi

  aws_cmd s3api put-bucket-versioning --bucket "$bucket" \
    --versioning-configuration Status=Enabled

  aws_cmd s3api put-bucket-encryption --bucket "$bucket" \
    --server-side-encryption-configuration '{
      "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
    }'

  aws_cmd s3api put-public-access-block --bucket "$bucket" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  echo "    Created."
}

create_bucket "$STATE_BUCKET"
create_bucket "$DEPLOY_BUCKET"

echo "==> Uploading redeploy.sh to s3://$DEPLOY_BUCKET/scripts/redeploy.sh"
aws_cmd s3 cp "$SCRIPT_DIR/redeploy.sh" "s3://$DEPLOY_BUCKET/scripts/redeploy.sh"

echo ""
echo "Bootstrap complete. Next steps:"
echo "  1. cd terraform && tofu init"
echo "  2. tofu plan"
echo "  3. tofu apply"
