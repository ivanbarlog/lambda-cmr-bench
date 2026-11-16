#!/bin/bash
# Tear down EVERYTHING the benchmark created (mirror of setup.sh + deploy-*.sh).
#
# Removes, in dependency order:
#   1. Lambda functions        (Bun matrix + docker variants + node baseline; all via aws lambda)
#   1b. CloudWatch log groups  (/aws/lambda/<fn> — not auto-deleted with the fn)
#   2. CMR runtime alias -> versions -> runtime resource
#   3. Bun runtime layer       (all versions)
#   4. ECR repositories        (CMR runtime image + docker function images, with images)
#   5. S3 bench bucket         (emptied first)
#   6. IAM role                (only with --iam; off by default)
#
# Uses the names from config.sh, so it deletes exactly what this project deploys
# and nothing else. DESTRUCTIVE — dry-run by default.
#
# Usage:
#   ./destroy.sh            # preview (dry-run)
#   ./destroy.sh --yes      # delete functions/runtime/layer/ECR/bucket
#   ./destroy.sh --yes --iam   # also delete the IAM role
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

DO_IT=0
DEL_IAM=0
for arg in "$@"; do
  case "$arg" in
    --yes) DO_IT=1 ;;
    --iam) DEL_IAM=1 ;;
  esac
done

run() {
  if [ "${DO_IT}" = "1" ]; then
    echo "    + $*"
    "$@" >/dev/null 2>&1 || echo "      (skipped/failed: $*)"
  else
    echo "    [dry-run] $*"
  fi
}

echo "==> Region ${AWS_REGION}  Account ${ACCOUNT_ID}"
[ "${DO_IT}" = "1" ] || echo "    (DRY RUN — add --yes to delete)"

# 1. Functions ----------------------------------------------------------------
echo "==> Lambda functions"
for fn in "${FN_CMR_BUN}" "${FN_CMR_AWSSDK}" "${FN_LAYER_BUN}" "${FN_LAYER_AWSSDK}" "${FN_NODE_AWSSDK}" \
          "${FN_DOCKER_BUN}" "${FN_DOCKER_AWSSDK}" \
          "${FN_DOCKER_BUN_SNAP}" "${FN_DOCKER_AWSSDK_SNAP}"; do
  if aws lambda get-function --function-name "${fn}" >/dev/null 2>&1; then
    run aws lambda delete-function --function-name "${fn}"
  else
    echo "    ${fn}: not found"
  fi
done

# 1b. CloudWatch log groups ---------------------------------------------------
# Lambda auto-creates /aws/lambda/<fn> log groups; deleting the function does NOT
# delete them, so remove them explicitly (they hold the benchmark log data).
echo "==> CloudWatch log groups"
for fn in "${FN_CMR_BUN}" "${FN_CMR_AWSSDK}" "${FN_LAYER_BUN}" "${FN_LAYER_AWSSDK}" "${FN_NODE_AWSSDK}" \
          "${FN_DOCKER_BUN}" "${FN_DOCKER_AWSSDK}" "${FN_DOCKER_BUN_SNAP}" "${FN_DOCKER_AWSSDK_SNAP}"; do
  lg="/aws/lambda/${fn}"
  if aws logs describe-log-groups --log-group-name-prefix "${lg}" \
       --query "logGroups[?logGroupName=='${lg}'].logGroupName" --output text 2>/dev/null | grep -q "${lg}"; then
    run aws logs delete-log-group --log-group-name "${lg}"
  else
    echo "    ${lg}: not found"
  fi
done

# 2. CMR runtime: alias -> versions -> runtime --------------------------------
echo "==> CMR runtime ${RUNTIME_NAME}"
if aws lambda-core get-runtime --runtime-name "${RUNTIME_NAME}" >/dev/null 2>&1; then
  aliases=$(aws lambda-core list-runtime-aliases --runtime-name "${RUNTIME_NAME}" \
    --query 'Items[].Name' --output text 2>/dev/null || echo "")
  for alias in ${aliases}; do
    run aws lambda-core delete-runtime-alias --runtime-name "${RUNTIME_NAME}" --name "${alias}"
  done

  versions=$(aws lambda-core list-runtime-versions --runtime-name "${RUNTIME_NAME}" \
    --query 'Items[].Name' --output text 2>/dev/null || echo "")
  for version in ${versions}; do
    run aws lambda-core delete-runtime-version --runtime-name "${RUNTIME_NAME}" --name "${version}"
  done

  run aws lambda-core delete-runtime --runtime-name "${RUNTIME_NAME}"
  echo "    note: runtime deletion is soft (PENDING_DELETION for 30 days); the name stays"
  echo "          reserved, so use a new RUNTIME_NAME if you run setup.sh again before then."
else
  echo "    ${RUNTIME_NAME}: not found"
fi

# 3. Layer --------------------------------------------------------------------
echo "==> Bun runtime layer ${LAYER_NAME}"
layer_versions=$(aws lambda list-layer-versions --layer-name "${LAYER_NAME}" \
  --query 'LayerVersions[].Version' --output text 2>/dev/null || echo "")
if [ -n "${layer_versions}" ]; then
  for lv in ${layer_versions}; do
    run aws lambda delete-layer-version --layer-name "${LAYER_NAME}" --version-number "${lv}"
  done
else
  echo "    ${LAYER_NAME}: no versions"
fi

# 4. ECR repositories --------------------------------------------------------
echo "==> ECR repository ${REPO_NAME} (CMR runtime image)"
if aws ecr describe-repositories --repository-names "${REPO_NAME}" --region "${REPO_REGION}" >/dev/null 2>&1; then
  run aws ecr delete-repository --repository-name "${REPO_NAME}" --force --region "${REPO_REGION}"
else
  echo "    ${REPO_NAME}: not found"
fi

echo "==> ECR repository ${FN_REPO_NAME} (docker function images)"
if aws ecr describe-repositories --repository-names "${FN_REPO_NAME}" --region "${REPO_REGION}" >/dev/null 2>&1; then
  run aws ecr delete-repository --repository-name "${FN_REPO_NAME}" --force --region "${REPO_REGION}"
else
  echo "    ${FN_REPO_NAME}: not found"
fi

# 5. S3 bucket ----------------------------------------------------------------
echo "==> S3 bucket ${BENCH_BUCKET}"
if aws s3api head-bucket --bucket "${BENCH_BUCKET}" 2>/dev/null; then
  if [ "${DO_IT}" = "1" ]; then
    echo "    + emptying s3://${BENCH_BUCKET}"
    aws s3 rm "s3://${BENCH_BUCKET}" --recursive >/dev/null 2>&1 || true
  else
    echo "    [dry-run] aws s3 rm s3://${BENCH_BUCKET} --recursive"
  fi
  run aws s3api delete-bucket --bucket "${BENCH_BUCKET}" --region "${AWS_REGION}"
else
  echo "    ${BENCH_BUCKET}: not found"
fi

# 6. IAM role (opt-in) --------------------------------------------------------
echo "==> IAM role ${ROLE_NAME}"
if [ "${DEL_IAM}" = "1" ]; then
  if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
    run aws iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name "bench-s3-access"
    run aws iam detach-role-policy --role-name "${ROLE_NAME}" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    run aws iam delete-role --role-name "${ROLE_NAME}"
  else
    echo "    ${ROLE_NAME}: not found"
  fi
else
  echo "    skipped (pass --iam to delete the role too)"
fi

echo
if [ "${DO_IT}" = "1" ]; then
  echo "Done. Benchmark resources removed."
else
  echo "DRY RUN complete — nothing deleted."
  echo "Delete for real:  ./destroy.sh --yes           (leaves the IAM role)"
  echo "                  ./destroy.sh --yes --iam      (also deletes the IAM role)"
fi
