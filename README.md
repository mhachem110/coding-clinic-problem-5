# EBS snapshot backup and retention

## Problem

Back up EBS volumes attached to running EC2 instances tagged `Backup=true`, then remove this automation's snapshots when they are older than 30 days.

## How it works

`ebs-snapshot-backup.sh` uses AWS CLI to find matching instances in one AWS region. For each attached EBS volume, it checks for a `pending` or `completed` snapshot with today's UTC `BackupDate`. If none exists, it creates a snapshot with `CreatedBy=ebs-snapshot-backup`, `BackupDate`, and `SourceInstanceId` tags.

It then lists snapshots owned by the account and tagged `CreatedBy=ebs-snapshot-backup`. A snapshot older than 30 days can be deleted unless it has `Retain=true` or is the newest completed snapshot for its volume. Failed API calls are reported; a failed backup stops retention for that run. This is one region per run and creates snapshots one volume at a time, so snapshots across an instance are **not** a crash-consistent set.

## Prerequisites and permissions

- Bash 4 or newer, AWS CLI, and jq
- AWS credentials from a profile, environment variables, or an instance role
- An AWS region set through `AWS_REGION`, `AWS_DEFAULT_REGION`, or the AWS CLI configuration
- An IAM principal with the permissions in [`iam/policy.json`](iam/policy.json)

The policy grants read access to EC2 inventory, snapshot creation and tagging at creation, and deletion only when `CreatedBy=ebs-snapshot-backup`. EC2 requires the describe actions to use `Resource: *`. Because the script selects volumes through their **instance** tag, the create permission covers volumes in the selected regions; use an account or role dedicated to this job. `sts:GetCallerIdentity` is called to check credentials and does not require an IAM allow statement. Encrypted volumes using a customer managed KMS key may need additional key permissions.

## Configure and run

Tag each instance you want included, then set a region and use dry run before the real run:

```bash
aws ec2 create-tags --resources i-0123456789abcdef0 --tags Key=Backup,Value=true
export AWS_REGION=us-east-1
bash ebs-snapshot-backup.sh --dry-run
bash ebs-snapshot-backup.sh
```

[`config/backup.env.example`](config/backup.env.example) shows the environment settings. If you use an AWS profile, set `AWS_PROFILE` as well. The script never stores credentials. It accepts only `--dry-run`; that mode reads AWS inventory and prints proposed changes without creating or deleting snapshots.

Example output:

```text
DRY RUN: would snapshot vol-0123456789abcdef0 for i-0123456789abcdef0
DRY RUN: would delete snap-0123456789abcdef0 for vol-0123456789abcdef0
```

A real run prints `CREATED`, `DELETED`, `SKIP`, or `FAILED` messages. Repeating a successful run on the same UTC day skips volumes with an existing backup. Retention excludes manual snapshots and other tools' snapshots by owner and the `CreatedBy` tag. To preserve a managed snapshot, add `Retain=true` before it reaches the 30-day cutoff. The newest **completed** snapshot per volume stays even if it is older; a pending or failed snapshot does not replace it. Snapshot creation is asynchronous, so `CREATED` means AWS accepted the request, not that the snapshot has finished.

## Tests

No AWS account is needed for the mocked tests:

```bash
bash -n ebs-snapshot-backup.sh tests/test-backup.sh
shellcheck ebs-snapshot-backup.sh tests/test-backup.sh
bash tests/test-backup.sh
```

The GitHub Actions workflow runs the same checks. Live AWS backup and deletion were not used to validate this project.
