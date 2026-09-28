#!/usr/bin/env bash
# Build the .NET image for linux/amd64 and push it to ECR.
#
# Called automatically by terraform (null_resource.build_and_push) with the
# environment pre-populated. Can also be run by hand:
#
#   AWS_REGION=us-east-1 \
#   ECR_REPO_URL=123456789012.dkr.ecr.us-east-1.amazonaws.com/dd-fargate-dynamic \
#   IMAGE_TAG=manual \
#   ./scripts/build_and_push.sh
set -euo pipefail

: "${AWS_REGION:?AWS_REGION is required}"
: "${ECR_REPO_URL:?ECR_REPO_URL is required}"
: "${IMAGE_TAG:?IMAGE_TAG is required}"

TRACER_VERSION="${TRACER_VERSION:-3.54.0}"
APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../app" && pwd)}"
REGISTRY="${ECR_REPO_URL%%/*}"
IMAGE="${ECR_REPO_URL}:${IMAGE_TAG}"

echo "==> logging in to ${REGISTRY}"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

if aws ecr describe-images \
      --region "${AWS_REGION}" \
      --repository-name "${ECR_REPO_URL#*/}" \
      --image-ids "imageTag=${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "==> ${IMAGE} already in ECR, skipping build"
  exit 0
fi

echo "==> building ${IMAGE} (linux/amd64, tracer ${TRACER_VERSION})"
# --provenance=false keeps the pushed artifact a plain image manifest rather than
# an OCI index, which ECS on Fargate is happier with.
docker buildx build \
  --platform linux/amd64 \
  --provenance=false \
  --build-arg "TRACER_VERSION=${TRACER_VERSION}" \
  -t "${IMAGE}" \
  --push \
  "${APP_DIR}"

echo "==> pushed ${IMAGE}"
