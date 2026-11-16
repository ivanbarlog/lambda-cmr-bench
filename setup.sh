#!/bin/bash
# One-time shared infrastructure: S3 bucket + IAM execution role with S3 access.
# Idempotent — safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

echo "==> S3 bucket: ${BENCH_BUCKET}"
if aws s3api head-bucket --bucket "${BENCH_BUCKET}" 2>/dev/null; then
  echo "    exists"
else
  aws s3api create-bucket \
    --bucket "${BENCH_BUCKET}" \
    --region "${AWS_REGION}" \
    --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
  echo "    created"
fi

echo "==> IAM role: ${ROLE_NAME}"
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "    exists"
else
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": { "Service": "lambda.amazonaws.com" },
          "Action": "sts:AssumeRole"
        }
      ]
    }'
  aws iam attach-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  echo "    created + attached basic execution policy"
fi

echo "==> Inline S3 access policy for bucket ${BENCH_BUCKET}"
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "bench-s3-access" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:PutObject\", \"s3:GetObject\", \"s3:ListBucket\", \"s3:DeleteObject\"],
        \"Resource\": [
          \"arn:aws:s3:::${BENCH_BUCKET}\",
          \"arn:aws:s3:::${BENCH_BUCKET}/*\"
        ]
      }
    ]
  }"

echo "==> Waiting 10s for role propagation..."
sleep 10
echo "Role ready: ${ROLE_ARN}"

# --- CMR runtime: build image, create runtime + version + alias ---------------
# This establishes the customer-managed runtime that the CMR benchmark functions
# attach to. deploy-cmr.sh then only creates/updates the functions.
echo
echo "==> Building runtime bundle + image (${DOCKER_PLATFORM}) and pushing to ECR"
if ! aws ecr describe-repositories --repository-names "${REPO_NAME}" --region "${REPO_REGION}" >/dev/null 2>&1; then
  echo "    creating ECR repo ${REPO_NAME}"
  aws ecr create-repository --repository-name "${REPO_NAME}" --region "${REPO_REGION}" >/dev/null
  aws ecr set-repository-policy \
    --repository-name "${REPO_NAME}" \
    --region "${REPO_REGION}" \
    --policy-text '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "LambdaReadAccess",
          "Effect": "Allow",
          "Principal": { "Service": "lambda.amazonaws.com" },
          "Action": ["ecr:BatchGetImage", "ecr:DescribeImages", "ecr:GetDownloadUrlForLayer"]
        }
      ]
    }' >/dev/null
fi

aws ecr get-login-password --region "${REPO_REGION}" \
  | docker login --username AWS --password-stdin \
    "${ACCOUNT_ID}.dkr.ecr.${REPO_REGION}.amazonaws.com"

docker buildx create --name cmrbuilder --driver docker-container --use 2>/dev/null \
  || docker buildx use cmrbuilder

# CMR needs a Docker v2 Schema 2 image (not OCI); re-verify against
# the current docs before dropping oci-mediatypes=false. Build context is this repo
# (Dockerfile + runtime/ live here).
docker buildx build \
  --platform "${DOCKER_PLATFORM}" \
  --tag "${ECR_URI}:${IMAGE_TAG}" \
  --output type=image,oci-mediatypes=false \
  --provenance=false \
  --sbom=false \
  --push .

echo "==> Ensuring runtime resource ${RUNTIME_NAME}"
# Deleting a runtime is soft: it stays PENDING_DELETION (name reserved) for 30 days.
RUNTIME_STATE=$(aws lambda-core get-runtime --runtime-name "${RUNTIME_NAME}" \
  --query 'State' --output text 2>/dev/null || echo "NONE")
if [ "${RUNTIME_STATE}" = "PENDING_DELETION" ]; then
  echo "Runtime ${RUNTIME_NAME} is PENDING_DELETION (left over from destroy.sh)." >&2
  echo "Use a fresh name:  RUNTIME_NAME=<new-name> ./setup.sh   (export it for the other scripts too)" >&2
  exit 1
fi
aws lambda-core get-runtime --runtime-name "${RUNTIME_NAME}" >/dev/null 2>&1 \
  || aws lambda-core create-runtime --name "${RUNTIME_NAME}" \
       --description "Bun CMR benchmark runtime" --license-info "None" >/dev/null
RUNTIME_ARN=$(aws lambda-core get-runtime --runtime-name "${RUNTIME_NAME}" \
  --query 'Arn' --output text)
echo "    RUNTIME_ARN=${RUNTIME_ARN}"

echo "==> Creating runtime version ${RUNTIME_VERSION}"
aws lambda-core create-runtime-version \
  --runtime-name "${RUNTIME_NAME}" \
  --image-uri "${ECR_URI}:${IMAGE_TAG}" \
  --name "${RUNTIME_VERSION}" >/dev/null 2>&1 \
  || echo "    version ${RUNTIME_VERSION} already exists — reusing"

echo "==> Waiting for version ${RUNTIME_VERSION} to be ACTIVE"
aws lambda-core wait runtime-version-active \
  --runtime-name "${RUNTIME_NAME}" --name "${RUNTIME_VERSION}"

echo "==> Pointing alias ${RUNTIME_ALIAS} -> ${RUNTIME_VERSION}"
if aws lambda-core get-runtime-alias --runtime-name "${RUNTIME_NAME}" \
     --name "${RUNTIME_ALIAS}" >/dev/null 2>&1; then
  aws lambda-core update-runtime-alias --runtime-name "${RUNTIME_NAME}" \
    --name "${RUNTIME_ALIAS}" --runtime-version "${RUNTIME_VERSION}" >/dev/null
else
  aws lambda-core create-runtime-alias --runtime-name "${RUNTIME_NAME}" \
    --name "${RUNTIME_ALIAS}" --runtime-version "${RUNTIME_VERSION}" >/dev/null
fi
aws lambda-core wait runtime-alias-active \
  --runtime-name "${RUNTIME_NAME}" --name "${RUNTIME_ALIAS}"

echo
echo "Done. Bucket=${BENCH_BUCKET} Role=${ROLE_ARN}"
echo "Runtime=${RUNTIME_NAME} version=${RUNTIME_VERSION} alias=${RUNTIME_ALIAS}"
echo "Next: ./deploy-cmr.sh && ./deploy-layer.sh && ./deploy-docker.sh && ./deploy-node.sh"
