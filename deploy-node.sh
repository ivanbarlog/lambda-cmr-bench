#!/bin/bash
# Deploy the Node.js baseline benchmark function: the OFFICIAL AWS managed runtime
# (nodejs24.x) with @aws-sdk/client-s3 BUNDLED into the deployment zip.
#
# Uses the STANDARD `aws lambda` service (like deploy-layer.sh). This is the only
# variant not running Bun — it's the managed-runtime baseline for the aws-sdk S3
# client. --tenancy-config PER_TENANT forces cold starts the same way as the
# other functions. The handler is bundled with `bun build --target=node`, so the
# SDK ships in the zip rather than being resolved from the runtime.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

# Deploy the node function (single S3-client variant: aws-sdk, bundled).
deploy_node_fn() {
  local client="node" fn="${FN_NODE_AWSSDK}" label="node"
  local zip="/tmp/bench-${client}.zip"
  echo "==> [${label}] packaging handler-${client} (--target=node)"
  build_handler_zip "${client}" "${zip}"

  local env_json
  env_json="{\"Variables\":{\"BENCH_BUCKET\":\"${BENCH_BUCKET}\",\"BENCH_RUNTIME_LABEL\":\"${label}\",\"BENCH_FILE_COUNT\":\"${BENCH_FILE_COUNT}\",\"BENCH_FILE_SIZE_BYTES\":\"${BENCH_FILE_SIZE_BYTES}\",\"BENCH_PASSES\":\"${BENCH_PASSES}\"}}"

  echo "==> [${label}] creating/updating function ${fn} (runtime ${NODE_RUNTIME})"
  if aws lambda get-function --function-name "${fn}" >/dev/null 2>&1; then
    aws lambda update-function-code \
      --function-name "${fn}" --zip-file "fileb://${zip}" >/dev/null
    aws lambda wait function-updated --function-name "${fn}"
    aws lambda update-function-configuration \
      --function-name "${fn}" \
      --runtime "${NODE_RUNTIME}" \
      --handler "bench-${client}.handler" \
      --memory-size "${MEMORY_SIZE}" --timeout "${TIMEOUT}" \
      --environment "${env_json}" >/dev/null
    aws lambda wait function-updated --function-name "${fn}"
  else
    aws lambda create-function \
      --function-name "${fn}" \
      --runtime "${NODE_RUNTIME}" \
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

deploy_node_fn

echo "Done. Node function: ${FN_NODE_AWSSDK} (runtime ${NODE_RUNTIME}, aws-sdk bundled)"
