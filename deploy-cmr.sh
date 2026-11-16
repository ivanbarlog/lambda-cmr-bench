#!/bin/bash
# Deploy the CMR (customer-managed runtime) benchmark functions - both S3-client
# variants: bun-native and aws-sdk. The runtime image/version/alias is created by
# setup.sh; this script only creates/updates the functions that attach to it.
# Functions use the standard `aws lambda` service with --runtime-config.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

echo "==> Resolving runtime ${RUNTIME_NAME} (created by setup.sh)"
if ! aws lambda-core get-runtime --runtime-name "${RUNTIME_NAME}" >/dev/null 2>&1; then
  echo "Runtime ${RUNTIME_NAME} not found — run ./setup.sh first." >&2
  exit 1
fi
RUNTIME_ARN=$(aws lambda-core get-runtime --runtime-name "${RUNTIME_NAME}" \
  --query 'Arn' --output text)
echo "    RUNTIME_ARN=${RUNTIME_ARN}"

# Sanity: the alias must exist and be ACTIVE, otherwise functions will fail.
ALIAS_STATE=$(aws lambda-core get-runtime-alias --runtime-name "${RUNTIME_NAME}" \
  --name "${RUNTIME_ALIAS}" --query 'State' --output text 2>/dev/null || echo "MISSING")
if [ "${ALIAS_STATE}" != "ACTIVE" ]; then
  echo "Runtime alias ${RUNTIME_ALIAS} is '${ALIAS_STATE}' (expected ACTIVE) — run ./setup.sh first." >&2
  exit 1
fi

# Wait until the function's last update finished (standard Lambda waiter; CMR
# config updates can otherwise race with the next update call).
wait_cmr_updated() {
  local fn="$1"
  aws lambda wait function-updated-v2 --function-name "${fn}"
}

# Deploy one CMR function for a given S3-client variant.
#   $1 = client (bun | awssdk)   $2 = function name   $3 = runtime label
deploy_cmr_fn() {
  local client="$1" fn="$2" label="$3"
  local zip="/tmp/bench-${client}.zip"
  echo "==> [${label}] packaging handler-${client}"
  build_handler_zip "${client}" "${zip}"

  local env_json
  env_json="{\"Variables\":{\"BENCH_BUCKET\":\"${BENCH_BUCKET}\",\"BENCH_RUNTIME_LABEL\":\"${label}\",\"BENCH_FILE_COUNT\":\"${BENCH_FILE_COUNT}\",\"BENCH_FILE_SIZE_BYTES\":\"${BENCH_FILE_SIZE_BYTES}\",\"BENCH_PASSES\":\"${BENCH_PASSES}\"}}"

  echo "==> [${label}] creating/updating function ${fn}"
  local runtime_config="{\"RuntimeArn\":\"${RUNTIME_ARN}\",\"RuntimeAlias\":\"${RUNTIME_ALIAS}\"}"
  if aws lambda get-function --function-name "${fn}" >/dev/null 2>&1; then
    aws lambda update-function-code \
      --function-name "${fn}" --zip-file "fileb://${zip}" >/dev/null
    wait_cmr_updated "${fn}"
    # NOTE: always re-set --runtime-config so an existing function is repointed
    # at the correct runtime/alias (guards against a function left bound to a
    # stale/broken runtime from an earlier manual walkthrough).
    aws lambda update-function-configuration \
      --function-name "${fn}" \
      --runtime-config "${runtime_config}" \
      --memory-size "${MEMORY_SIZE}" --timeout "${TIMEOUT}" \
      --environment "${env_json}" >/dev/null
    wait_cmr_updated "${fn}"
  else
    aws lambda create-function \
      --function-name "${fn}" \
      --runtime "custom" \
      --runtime-config "${runtime_config}" \
      --handler "bench-${client}.handler" \
      --role "${ROLE_ARN}" \
      --zip-file "fileb://${zip}" \
      --memory-size "${MEMORY_SIZE}" \
      --timeout "${TIMEOUT}" \
      --architectures "${ARCH}" \
      --environment "${env_json}" \
      --tenancy-config '{"TenantIsolationMode": "PER_TENANT"}' >/dev/null
    aws lambda wait function-active-v2 --function-name "${fn}"
  fi
}

deploy_cmr_fn "bun"    "${FN_CMR_BUN}"    "cmr"
deploy_cmr_fn "awssdk" "${FN_CMR_AWSSDK}" "cmr"

echo "Done. CMR functions: ${FN_CMR_BUN}, ${FN_CMR_AWSSDK}"
