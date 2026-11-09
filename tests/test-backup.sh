#!/usr/bin/env bash
set -eu

project=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/aws" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_LOG"
case "$1 $2" in
  'sts get-caller-identity') printf '%s\n' '{"Account":"123456789012"}' ;;
  'ec2 describe-instances') printf '%s\n' "$MOCK_INSTANCES" ;;
  'ec2 describe-snapshots')
    [[ ${MOCK_FAIL:-} != list ]] || exit 1
    printf '%s\n' "$MOCK_SNAPSHOTS" ;;
  'ec2 create-snapshot')
    [[ ${MOCK_FAIL:-} != create ]] || exit 1
    printf '%s\n' '{"SnapshotId":"snap-new"}' ;;
  'ec2 delete-snapshot')
    [[ ${MOCK_FAIL:-} != delete ]] || exit 1 ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$tmp/aws"
export PATH="$tmp:$PATH" MOCK_LOG="$tmp/calls" AWS_REGION=us-east-1
today=$(date -u +%F)
old=$(date -u -d '40 days ago' +%FT%TZ)
older=$(date -u -d '50 days ago' +%FT%TZ)
export MOCK_INSTANCES='{"Reservations":[{"Instances":[{"InstanceId":"i-1","BlockDeviceMappings":[{"Ebs":{"VolumeId":"vol-1"}}]}]}]}'
export MOCK_SNAPSHOTS='{"Snapshots":[]}'

run_case() {
  : >"$MOCK_LOG"
  if output=$(bash "$project/ebs-snapshot-backup.sh" "$@" 2>&1); then
    status=0
  else
    status=$?
  fi
}
expect() {
  if ! grep -Fq -- "$1" <<<"$2"; then
    printf 'FAIL: expected %s\n%s\n' "$1" "$2" >&2
    exit 1
  fi
}
reject() {
  if grep -Fq -- "$1" <<<"$2"; then
    printf 'FAIL: unexpected %s\n%s\n' "$1" "$2" >&2
    exit 1
  fi
}

run_case
[[ $status == 0 ]]
expect 'CREATED snap-new for vol-1' "$output"
expect 'Name=instance-state-name,Values=running Name=tag:Backup,Values=true' "$(cat "$MOCK_LOG")"
expect 'Key=CreatedBy,Value=ebs-snapshot-backup' "$(cat "$MOCK_LOG")"
echo 'PASS instance filtering and snapshot creation'

export MOCK_SNAPSHOTS="{\"Snapshots\":[{\"SnapshotId\":\"snap-today\",\"VolumeId\":\"vol-1\",\"State\":\"completed\",\"StartTime\":\"${today}T01:00:00Z\",\"Tags\":[{\"Key\":\"CreatedBy\",\"Value\":\"ebs-snapshot-backup\"},{\"Key\":\"BackupDate\",\"Value\":\"$today\"}]}]}"
run_case
[[ $status == 0 ]]
expect 'SKIP vol-1: backup already exists' "$output"
reject 'create-snapshot' "$(cat "$MOCK_LOG")"
echo 'PASS duplicate prevention'

export MOCK_SNAPSHOTS="{\"Snapshots\":[
  {\"SnapshotId\":\"snap-old\",\"VolumeId\":\"vol-1\",\"State\":\"completed\",\"StartTime\":\"$old\",\"Tags\":[{\"Key\":\"CreatedBy\",\"Value\":\"ebs-snapshot-backup\"}]},
  {\"SnapshotId\":\"snap-keep\",\"VolumeId\":\"vol-1\",\"State\":\"completed\",\"StartTime\":\"${today}T00:00:00Z\",\"Tags\":[{\"Key\":\"CreatedBy\",\"Value\":\"ebs-snapshot-backup\"}]},
  {\"SnapshotId\":\"snap-retain\",\"VolumeId\":\"vol-2\",\"State\":\"error\",\"StartTime\":\"$old\",\"Tags\":[{\"Key\":\"CreatedBy\",\"Value\":\"ebs-snapshot-backup\"},{\"Key\":\"Retain\",\"Value\":\"true\"}]},
  {\"SnapshotId\":\"snap-manual\",\"VolumeId\":\"vol-3\",\"State\":\"completed\",\"StartTime\":\"$old\",\"Tags\":[]}] }"
run_case --dry-run
[[ $status == 0 ]]
expect 'DRY RUN: would snapshot vol-1' "$output"
expect 'DRY RUN: would delete snap-old' "$output"
reject 'snap-retain' "$output"
reject 'snap-manual' "$output"
reject 'create-snapshot' "$(cat "$MOCK_LOG")"
reject 'delete-snapshot' "$(cat "$MOCK_LOG")"
echo 'PASS dry-run safety and retention selection'

run_case
[[ $status == 0 ]]
expect 'DELETED snap-old' "$output"
expect 'delete-snapshot --region us-east-1 --snapshot-id snap-old' "$(cat "$MOCK_LOG")"
reject 'snapshot-id snap-keep' "$(cat "$MOCK_LOG")"
reject 'snapshot-id snap-retain' "$(cat "$MOCK_LOG")"
reject 'snapshot-id snap-manual' "$(cat "$MOCK_LOG")"
echo 'PASS retention guards'

export MOCK_SNAPSHOTS="{\"Snapshots\":[
  {\"SnapshotId\":\"snap-older\",\"VolumeId\":\"vol-1\",\"State\":\"completed\",\"StartTime\":\"$older\",\"Tags\":[{\"Key\":\"CreatedBy\",\"Value\":\"ebs-snapshot-backup\"}]},
  {\"SnapshotId\":\"snap-last\",\"VolumeId\":\"vol-1\",\"State\":\"completed\",\"StartTime\":\"$old\",\"Tags\":[{\"Key\":\"CreatedBy\",\"Value\":\"ebs-snapshot-backup\"}]}]}"
run_case --dry-run
[[ $status == 0 ]]
expect 'would delete snap-older' "$output"
reject 'would delete snap-last' "$output"
echo 'PASS newest completed snapshot survives expiry'

export MOCK_FAIL=list
run_case
[[ $status == 1 ]]
reject 'create-snapshot' "$(cat "$MOCK_LOG")"
reject 'delete-snapshot' "$(cat "$MOCK_LOG")"
unset MOCK_FAIL
echo 'PASS failed inventory stops changes'

export MOCK_FAIL=create
run_case
[[ $status == 1 ]]
expect 'retention skipped' "$output"
reject 'delete-snapshot' "$(cat "$MOCK_LOG")"
unset MOCK_FAIL
echo 'PASS backup failure stops retention'
