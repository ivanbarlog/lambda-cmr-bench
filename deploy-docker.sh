#!/bin/bash
# Deploy the "bun in docker" benchmark functions: REAL container-image Lambdas
# (--package-type Image) running the same Bun runtime as the CMR/layer variants,
# for both S3 clients (bun-native, aws-sdk), each WITH and WITHOUT SnapStart.
#
# Uses the STANDARD `aws lambda` service (no customer-managed runtime), so SnapStart is
# available. SnapStart for container images is GA; a custom base image needs no
# restore hooks because the Bun runtime simply blocks on the runtime-API "next"
# call while the snapshot is taken.
#
# Four functions:
#   docker/bun       no snapstart   FN_DOCKER_BUN
#   docker/aws-sdk   no snapstart   FN_DOCKER_AWSSDK
#   docker/bun       snapstart      FN_DOCKER_BUN_SNAP        (invoked via :snap alias)
#   docker/aws-sdk   snapstart      FN_DOCKER_AWSSDK_SNAP     (invoked via :snap alias)
#
# SnapStart applies only to PUBLISHED VERSIONS, so the snap functions get
# --snap-start ApplyOn=PublishedVersions, a published version, and the
# DOCKER_SNAP_ALIAS alias pointing at it (run-benchmark.sh invokes that alias).
# The non-snap functions are invoked on $LATEST like the other variants.
#
# TENANCY: SnapStart is incompatible with tenancy configuration. So only the
# non-snap functions use PER_TENANT (fresh --tenant-id forces a cold start). The
# snap functions omit tenancy; run-benchmark.sh forces their cold starts with a
# concurrent invoke burst and classifies cold vs warm from the REPORT "Restore
# Duration" field rather than from the tenant.
#
# The BENCH_RUNTIME_LABEL differs per SnapStart state (docker vs docker-snap) so
# compare.ts separates them into distinct variants.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

# 1. Function-image ECR repo (separate from the CMR runtime repo). ------------
echo "==> Ensuring function-image ECR repo ${FN_REPO_NAME}"
if ! aws ecr describe-repositories --repository-names "${FN_REPO_NAME}" --region "${REPO_REGION}" >/dev/null 2>&1; then
  aws ecr create-repository --repository-name "${FN_REPO_NAME}" --region "${REPO_REGION}" >/dev/null
  aws ecr set-repository-policy \
    --repository-name "${FN_REPO_NAME}" \
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
  echo "    created ${FN_REPO_NAME}"
else
  echo "    exists"
fi

aws ecr get-login-password --region "${REPO_REGION}" \
  | docker login --username AWS --password-stdin \
    "${ACCOUNT_ID}.dkr.ecr.${REPO_REGION}.amazonaws.com"

docker buildx create --name cmrbuilder --driver docker-container --use 2>/dev/null \
  || docker buildx use cmrbuilder

# 2. Build + push one function image per S3-client variant. -------------------
# Container-image Lambdas accept OCI images; unlike the CMR runtime image we do
# NOT need Schema-2. --provenance=false/--sbom=false keep a single image manifest
# (a multi-arch/attestation index is not directly usable by Lambda).
build_push_image() {
  local variant="$1" tag="$2"
  echo "==> [docker/${variant}] building + pushing image ${FN_ECR_URI}:${tag} (${DOCKER_PLATFORM})"
  docker buildx build \
    --platform "${DOCKER_PLATFORM}" \
    --build-arg "HANDLER_VARIANT=${variant}" \
    --file Dockerfile.function \
    --tag "${FN_ECR_URI}:${tag}" \
    --provenance=false \
    --sbom=false \
    --push .
}

build_push_image "bun"    "${FN_IMAGE_TAG_BUN}"
build_push_image "awssdk" "${FN_IMAGE_TAG_AWSSDK}"

# Resolve the immutable image digest for a tag so create/update pins an exact
# image (a moving tag can leave a function on a stale image after a rebuild).
image_uri_for_tag() {
  local tag="$1" digest
  digest=$(aws ecr describe-images \
    --repository-name "${FN_REPO_NAME}" --region "${REPO_REGION}" \
    --image-ids "imageTag=${tag}" \
    --query 'imageDetails[0].imageDigest' --output text)
  echo "${FN_ECR_URI}@${digest}"
}

# 3/4. Deploy one container-image function (optionally with SnapStart). --------
#   $1 = client (bun | awssdk)     $2 = image tag
#   $3 = function name             $4 = runtime label (docker | docker-snap)
#   $5 = snapstart (1|0)           $6 = handler command (bench-<client>.handler)
deploy_docker_fn() {
  local client="$1" tag="$2" fn="$3" label="$4" snap="$5" handler_cmd="$6"
  local image_uri
  image_uri="$(image_uri_for_tag "${tag}")"
  echo "==> [${label}] deploying ${fn} (image ${image_uri}, handler ${handler_cmd}, snapstart=${snap})"

  local env_json snap_json
  env_json="{\"Variables\":{\"BENCH_BUCKET\":\"${BENCH_BUCKET}\",\"BENCH_RUNTIME_LABEL\":\"${label}\",\"BENCH_FILE_COUNT\":\"${BENCH_FILE_COUNT}\",\"BENCH_FILE_SIZE_BYTES\":\"${BENCH_FILE_SIZE_BYTES}\",\"BENCH_PASSES\":\"${BENCH_PASSES}\"}}"
  # SnapStart is INCOMPATIBLE with tenancy configuration, so the snap functions
  # must NOT set --tenancy-config. Non-snap functions keep PER_TENANT (cold
  # starts are forced by a fresh --tenant-id, like every other variant). The
  # snap functions instead force cold starts with a concurrent burst and classify
  # cold vs warm from the REPORT "Restore Duration" field (see run-benchmark.sh).
  if [ "${snap}" = "1" ]; then
    snap_json='{"ApplyOn":"PublishedVersions"}'
  else
    snap_json='{"ApplyOn":"None"}'
  fi

  if aws lambda get-function --function-name "${fn}" >/dev/null 2>&1; then
    aws lambda update-function-code \
      --function-name "${fn}" --image-uri "${image_uri}" >/dev/null
    aws lambda wait function-updated --function-name "${fn}"
    aws lambda update-function-configuration \
      --function-name "${fn}" \
      --image-config "{\"Command\":[\"${handler_cmd}\"]}" \
      --memory-size "${MEMORY_SIZE}" --timeout "${TIMEOUT}" \
      --environment "${env_json}" \
      --snap-start "${snap_json}" >/dev/null
    aws lambda wait function-updated --function-name "${fn}"
  else
    # Tenancy only for the non-snap functions (SnapStart rejects tenancy-config).
    # bash 3.2 (macOS) errors on "${arr[@]}" when the array is empty under set -u,
    # so build the full arg array and only append tenancy when applicable.
    local create_args=(
      --function-name "${fn}"
      --package-type Image
      --code "ImageUri=${image_uri}"
      --image-config "{\"Command\":[\"${handler_cmd}\"]}"
      --role "${ROLE_ARN}"
      --memory-size "${MEMORY_SIZE}"
      --timeout "${TIMEOUT}"
      --architectures "${ARCH}"
      --environment "${env_json}"
      --snap-start "${snap_json}"
    )
    if [ "${snap}" != "1" ]; then
      create_args+=(--tenancy-config '{"TenantIsolationMode": "PER_TENANT"}')
    fi
    aws lambda create-function "${create_args[@]}" >/dev/null
    aws lambda wait function-active-v2 --function-name "${fn}"
  fi

  # For SnapStart, publish a version (this is when the snapshot is created) and
  # point the alias at it. Lambda runs the init phase and snapshots it at publish
  # time, so wait for the published version to be Active — and surface the reason
  # if it fails (e.g. init error / timeout) instead of a bare waiter error.
  if [ "${snap}" = "1" ]; then
    echo "    [${label}] publishing version (creates the SnapStart snapshot)"
    local version
    version=$(aws lambda publish-version --function-name "${fn}" \
      --query 'Version' --output text)
    if ! aws lambda wait function-active-v2 \
         --function-name "${fn}" --qualifier "${version}" 2>/dev/null; then
      echo "    !! [${label}] version ${version} failed to become Active. Reason:" >&2
      aws lambda get-function --function-name "${fn}" --qualifier "${version}" \
        --query 'Configuration.{State:State,StateReason:StateReason,StateReasonCode:StateReasonCode}' \
        --output json >&2 || true
      echo "       Check CloudWatch /aws/lambda/${fn} INIT_REPORT for the init error." >&2
      return 1
    fi
    echo "    [${label}] version ${version} active; pointing alias ${DOCKER_SNAP_ALIAS} -> ${version}"
    if aws lambda get-alias --function-name "${fn}" --name "${DOCKER_SNAP_ALIAS}" >/dev/null 2>&1; then
      aws lambda update-alias --function-name "${fn}" \
        --name "${DOCKER_SNAP_ALIAS}" --function-version "${version}" >/dev/null
    else
      aws lambda create-alias --function-name "${fn}" \
        --name "${DOCKER_SNAP_ALIAS}" --function-version "${version}" >/dev/null
    fi
  fi
}

# No SnapStart: invoked on $LATEST like the other variants (label "docker").
deploy_docker_fn "bun"    "${FN_IMAGE_TAG_BUN}"    "${FN_DOCKER_BUN}"    "docker" 0 "bench-bun.handler"
deploy_docker_fn "awssdk" "${FN_IMAGE_TAG_AWSSDK}" "${FN_DOCKER_AWSSDK}" "docker" 0 "bench-awssdk.handler"

# SnapStart: invoked via the ${DOCKER_SNAP_ALIAS} alias (label "docker-snap").
deploy_docker_fn "bun"    "${FN_IMAGE_TAG_BUN}"    "${FN_DOCKER_BUN_SNAP}"    "docker-snap" 1 "bench-bun.handler"
deploy_docker_fn "awssdk" "${FN_IMAGE_TAG_AWSSDK}" "${FN_DOCKER_AWSSDK_SNAP}" "docker-snap" 1 "bench-awssdk.handler"

echo "Done. Docker functions:"
echo "  no-snap : ${FN_DOCKER_BUN}, ${FN_DOCKER_AWSSDK}"
echo "  snap    : ${FN_DOCKER_BUN_SNAP}:${DOCKER_SNAP_ALIAS}, ${FN_DOCKER_AWSSDK_SNAP}:${DOCKER_SNAP_ALIAS}"
