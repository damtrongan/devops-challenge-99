#!/usr/bin/env bash
# Reads the image tag currently running as the "app" container on an EC2
# instance matching a Name tag, so a failed production deploy can roll back
# to exactly what was running before.
#
# Usage: get-current-tag.sh <instance-name-tag>
# Prints: tag=<value>   (designed to be appended straight to $GITHUB_OUTPUT)

set -euo pipefail

INSTANCE_TAG_VALUE="${1:?usage: get-current-tag.sh <instance-name-tag>}"

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${INSTANCE_TAG_VALUE}" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text)

if [ "$INSTANCE_ID" = "None" ] || [ -z "$INSTANCE_ID" ]; then
  echo "No running instance found for tag:Name=${INSTANCE_TAG_VALUE}" >&2
  exit 1
fi

COMMAND_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$INSTANCE_ID" \
  --parameters 'commands=["docker inspect --format \"{{index .Config.Image}}\" app | rev | cut -d: -f1 | rev"]' \
  --comment "Read currently deployed image tag" \
  --query "Command.CommandId" \
  --output text)

# A single, already-known instance ID: a short fixed wait is sufficient here
# (unlike deploy-backend.sh, which fans out to a whole tagged fleet).
sleep 5

TAG=$(aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --query "StandardOutputContent" \
  --output text | tr -d '[:space:]')

if [ -z "$TAG" ]; then
  echo "Failed to read current image tag from ${INSTANCE_ID}" >&2
  exit 1
fi

echo "tag=${TAG}"
