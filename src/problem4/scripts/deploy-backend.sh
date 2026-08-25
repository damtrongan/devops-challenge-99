#!/usr/bin/env bash
# Deploys a given image tag to the EC2 instances matching a Name tag, over
# AWS Systems Manager Run Command (no SSH ingress required to the fleet).
#
# Usage: deploy-backend.sh <image-tag> <instance-name-tag>
# Requires env: ECR_REGISTRY, ECR_REPOSITORY, AWS_REGION

set -euo pipefail

IMAGE_TAG="${1:?usage: deploy-backend.sh <image-tag> <instance-name-tag>}"
INSTANCE_TAG_VALUE="${2:?usage: deploy-backend.sh <image-tag> <instance-name-tag>}"
: "${ECR_REGISTRY:?ECR_REGISTRY env var required}"
: "${ECR_REPOSITORY:?ECR_REPOSITORY env var required}"
: "${AWS_REGION:?AWS_REGION env var required}"

IMAGE="${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"

# The instance already has an IAM instance profile allowing ECR pulls, so no
# credentials are shipped to it from this workflow.
REMOTE_SCRIPT=$(cat <<EOF
set -euo pipefail
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY}
docker pull ${IMAGE}
IMAGE_TAG=${IMAGE_TAG} docker compose -f /opt/app/docker-compose.yml up -d --no-deps app
docker image prune -f
EOF
)

echo "Deploying ${IMAGE} to instances tagged Name=${INSTANCE_TAG_VALUE}..."

COMMAND_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Name,Values=${INSTANCE_TAG_VALUE}" \
  --parameters "commands=[$(printf '%s' "$REMOTE_SCRIPT" | jq -Rs .)]" \
  --comment "Deploy backend image ${IMAGE_TAG}" \
  --query "Command.CommandId" \
  --output text)

echo "SSM command ID: ${COMMAND_ID}"

for attempt in $(seq 1 30); do
  sleep 10
  STATUS=$(aws ssm list-command-invocations \
    --command-id "$COMMAND_ID" \
    --query "CommandInvocations[0].Status" \
    --output text 2>/dev/null || echo "Pending")

  echo "Status: ${STATUS} (attempt ${attempt}/30)"

  case "$STATUS" in
    Success)
      echo "Deploy succeeded."
      exit 0
      ;;
    Failed | Cancelled | TimedOut)
      echo "Deploy failed with status ${STATUS}." >&2
      aws ssm list-command-invocations --command-id "$COMMAND_ID" --details \
        --query "CommandInvocations[].CommandPlugins[].Output" --output text >&2 || true
      exit 1
      ;;
  esac
done

echo "Timed out waiting for deployment to complete." >&2
exit 1
