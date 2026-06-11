#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-us-east-1}"

usage() {
  echo "Usage: $(basename "$0") <bucket-name> [--delete-bucket] [--region <region>]"
  echo ""
  echo "  Empties all object versions and delete markers from an S3 bucket."
  echo "  Optionally deletes the bucket itself with --delete-bucket."
  echo ""
  echo "  Env vars: AWS_PROFILE, AWS_DEFAULT_REGION (default: us-east-1)"
  exit 1
}

die() { echo "ERROR: $*" >&2; exit 1; }

aws_cmd() { aws --output text --no-cli-pager --region "$REGION" "$@"; }

delete_versions() {
  local bucket="$1"
  local jq_filter="$2"
  local label="$3"

  aws_cmd --output json s3api list-object-versions --bucket "$bucket" 2>/dev/null \
    | jq -r "${jq_filter}" \
    | while IFS=$'\t' read -r key vid; do
        echo "  Deleting ${label}: ${key} (${vid})"
        aws_cmd s3api delete-object --bucket "$bucket" --key "$key" --version-id "$vid"
      done
}

empty_bucket() {
  local bucket="$1"

  echo "Deleting object versions from s3://${bucket} ..."
  delete_versions "$bucket" '.Versions[]? | .Key + "\t" + .VersionId' "version"

  echo "Deleting delete markers from s3://${bucket} ..."
  delete_versions "$bucket" '.DeleteMarkers[]? | .Key + "\t" + .VersionId' "marker"
}

verify_empty() {
  local bucket="$1"
  local result
  result=$(aws_cmd --output json s3api list-object-versions --bucket "$bucket" 2>/dev/null)
  local versions markers
  versions=$(echo "$result" | jq '.Versions | length // 0')
  markers=$(echo "$result" | jq '.DeleteMarkers | length // 0')

  if [[ "$versions" -eq 0 && "$markers" -eq 0 ]]; then
    echo "Bucket s3://${bucket} is empty."
  else
    echo "WARNING: ${versions} version(s) and ${markers} marker(s) remain." >&2
    echo "$result"
    exit 1
  fi
}

main() {
  [[ $# -lt 1 ]] && usage

  local bucket=""
  local delete_bucket=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delete-bucket) delete_bucket=true ;;
      --region)        shift; REGION="${1:?--region requires a value}" ;;
      --help|-h)       usage ;;
      -*) die "Unknown flag: $1" ;;
      *)  [[ -z "$bucket" ]] && bucket="$1" || die "Unexpected argument: $1" ;;
    esac
    shift
  done

  [[ -z "$bucket" ]] && die "Bucket name is required."

  echo "==> Using AWS profile: ${AWS_PROFILE:-<default>}"
  echo "    Region:             ${REGION}"
  echo ""

  aws_cmd s3api head-bucket --bucket "$bucket" 2>/dev/null || die "Bucket '${bucket}' not found or not accessible."

  empty_bucket "$bucket"
  verify_empty "$bucket"

  if [[ "$delete_bucket" == true ]]; then
    echo "Deleting bucket s3://${bucket} ..."
    aws_cmd s3 rb "s3://${bucket}"
    echo "Bucket deleted."
  fi
}

main "$@"
