#!/usr/bin/env bash
set -u
set -o pipefail

dry_run=false
case "${1:-}" in
  --dry-run) dry_run=true ;;
  "") ;;
  *) echo "Usage: $0 [--dry-run]" >&2; exit 1 ;;
esac
if (( $# > 1 )); then
  echo "Usage: $0 [--dry-run]" >&2
  exit 1
fi

for tool in aws jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool is required" >&2
    exit 1
  fi
done

region=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}
if [[ -z $region ]]; then
  region=$(aws configure get region 2>/dev/null) || true
fi
if [[ -z $region ]]; then
  echo "ERROR: set AWS_REGION or configure a default region" >&2
  exit 1
fi
export AWS_PAGER=""
if ! aws sts get-caller-identity --region "$region" --output json >/dev/null; then
  echo "ERROR: AWS credentials are not available" >&2
  exit 1
fi

today=$(jq -nr 'now | strftime("%Y-%m-%d")')
cutoff=$(jq -nr 'now - 30 * 24 * 60 * 60 | floor')
marker=ebs-snapshot-backup

# Load both inventories before making changes. A failed or malformed read stops the run.
if ! instances=$(aws ec2 describe-instances --region "$region" \
  --filters 'Name=instance-state-name,Values=running' 'Name=tag:Backup,Values=true' \
  --output json); then
  echo "ERROR: could not list tagged running instances" >&2
  exit 1
fi
if ! snapshots=$(aws ec2 describe-snapshots --region "$region" --owner-ids self \
  --filters "Name=tag:CreatedBy,Values=$marker" --output json); then
  echo "ERROR: could not list managed snapshots" >&2
  exit 1
fi
if ! jq -e '.Reservations | type == "array"' >/dev/null <<<"$instances"; then
  echo "ERROR: invalid instance response" >&2
  exit 1
fi
if ! volumes=$(jq -r '.Reservations[].Instances[] | .InstanceId as $id |
  .BlockDeviceMappings[]? | select(.Ebs.VolumeId != null) |
  [$id, .Ebs.VolumeId] | @tsv' <<<"$instances"); then
  echo "ERROR: invalid instance response" >&2
  exit 1
fi
if ! jq -e '.Snapshots | type == "array"' >/dev/null <<<"$snapshots"; then
  echo "ERROR: invalid snapshot response" >&2
  exit 1
fi
if ! snapshots=$(jq -c --arg marker "$marker" '
  .Snapshots |= map(select(any(.Tags[]?; .Key == "CreatedBy" and .Value == $marker)))
' <<<"$snapshots"); then
  echo "ERROR: invalid snapshot tags" >&2
  exit 1
fi

failed=0
declare -A seen=()
while IFS=$'\t' read -r instance_id volume_id; do
  [[ -n $volume_id ]] || continue
  if [[ -n ${seen[$volume_id]:-} ]]; then
    echo "SKIP $volume_id: already processed in this run"
    continue
  fi
  seen[$volume_id]=1
  if ! existing=$(jq -r --arg volume "$volume_id" --arg day "$today" '
    [.Snapshots[] | select(.VolumeId == $volume and
      (.State == "pending" or .State == "completed") and
      any(.Tags[]?; .Key == "BackupDate" and .Value == $day))] | length
  ' <<<"$snapshots"); then
    echo "ERROR: could not check existing snapshots for $volume_id" >&2
    exit 1
  fi
  if (( existing > 0 )); then
    echo "SKIP $volume_id: backup already exists for $today"
    continue
  fi
  if $dry_run; then
    echo "DRY RUN: would snapshot $volume_id for $instance_id"
    continue
  fi
  tags="ResourceType=snapshot,Tags=[{Key=CreatedBy,Value=$marker},{Key=BackupDate,Value=$today},{Key=SourceInstanceId,Value=$instance_id}]"
  if result=$(aws ec2 create-snapshot --region "$region" --volume-id "$volume_id" \
    --description "Daily backup of $volume_id" --tag-specifications "$tags" --output json) &&
    snapshot_id=$(jq -er '.SnapshotId | select(type == "string")' <<<"$result"); then
    echo "CREATED $snapshot_id for $volume_id"
  else
    echo "FAILED to snapshot $volume_id" >&2
    failed=1
  fi
done <<<"$volumes"

if (( failed )); then
  echo "ERROR: backup failed; retention skipped" >&2
  exit 1
fi

# An old completed snapshot remains if it is the newest completed copy of its volume.
if ! protected=$(jq -c '[.Snapshots | map(select(.State == "completed")) |
  group_by(.VolumeId)[] | max_by(.StartTime).SnapshotId]' <<<"$snapshots"); then
  echo "ERROR: could not determine protected snapshots" >&2
  exit 1
fi
if ! expired=$(jq -r --argjson cutoff "$cutoff" --argjson protected "$protected" '
  .Snapshots[] |
  select(.State == "completed" or .State == "error") |
  select((any(.Tags[]?; .Key == "Retain" and .Value == "true")) | not) |
  select(.SnapshotId as $id | $protected | index($id) | not) |
  select((.StartTime | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") |
    fromdateiso8601) < $cutoff) |
  [.SnapshotId, .VolumeId] | @tsv
' <<<"$snapshots"); then
  echo "ERROR: could not evaluate snapshot retention" >&2
  exit 1
fi

while IFS=$'\t' read -r snapshot_id volume_id; do
  [[ -n $snapshot_id ]] || continue
  if $dry_run; then
    echo "DRY RUN: would delete $snapshot_id for $volume_id"
  elif aws ec2 delete-snapshot --region "$region" --snapshot-id "$snapshot_id"; then
    echo "DELETED $snapshot_id for $volume_id"
  else
    echo "FAILED to delete $snapshot_id" >&2
    failed=1
  fi
done <<<"$expired"

exit "$failed"
