#!/usr/bin/env bash
# Trigger a redeploy on the EC2 instance via SSH.
# Usage: ./scripts/deploy.sh [--profile <aws-profile>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REGION="us-east-1"
AWS_PROFILE="${AWS_PROFILE:-daveadmin}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --profile) AWS_PROFILE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

export AWS_PROFILE

echo "==> Fetching EC2 public IP from Tofu outputs"
cd "$REPO_ROOT/terraform"
INSTANCE_IP=$(AWS_PROFILE="$AWS_PROFILE" tofu output -raw alertstack_aws_public_ip 2>/dev/null || true)
if [[ -z "$INSTANCE_IP" ]]; then
  echo "ERROR: could not read alertstack_aws_public_ip from tofu output."
  echo "       Run: cd terraform && tofu apply"
  exit 1
fi
echo "    Instance IP: $INSTANCE_IP"

echo "==> Triggering redeploy on $INSTANCE_IP"
ssh -i ~/.ssh/alertstack-ec2.pem \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    ubuntu@"$INSTANCE_IP" "sudo /usr/local/bin/redeploy.sh"

echo ""
echo "Deployment complete."
echo "  Stack: https://$INSTANCE_IP:8443/"
