#!/bin/bash
# Deploy the layer-based (@beesolve/lambda-bun-runtime) benchmark functions —
# both S3-client variants: bun-native and aws-sdk.
#
# Uses the STANDARD `aws lambda` service (like the CDK BunFunction construct):
# a plain provided.al2023 Function + Bun layer. --tenancy-config PER_TENANT is
# added (a GA Lambda feature) so cold starts are forced the same way as CMR.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

if [ -z "${LAYER_ZIP:-}" ] || [ ! -f "${LAYER_ZIP}" ]; then
  echo "Layer zip not found (LAYER_ZIP='${LAYER_ZIP:-}')." >&2
  echo "Run 'bun install' so @beesolve/lambda-bun-runtime provides the layer zip," >&2
  echo "or set LAYER_ZIP to a bun-lambda-layer-*.zip explicitly." >&2
  exit 1
fi

echo "==> Publishing layer ${LAYER_NAME} from ${LAYER_ZIP} (standard aws lambda)"
LAYER_ARN=$(aws lambda publish-layer-version \
  --layer-name "${LAYER_NAME}" \
  --description "Bun 1.4.0 runtime layer (benchmark)" \
  --compatible-architectures "${ARCH}" \
  --compatible-runtimes "provided.al2023" \
  --zip-file "fileb://${LAYER_ZIP}" \
  --query 'LayerVersionArn' --output text)
echo "    LAYER_ARN=${LAYER_ARN}"

# Deploy one layer function for a given S3-client variant.
#   $1 = client (bun | awssdk)   $2 = function name   $3 = runtime label
deploy_layer_fn() {
  local client="$1" fn="$2" label="$3"
  local zip="/tmp/bench-${client}.zip"
  echo "==> [${label}] packaging handler-${client}"
  build_handler_zip "${client}" "${zip}"

  local env_json
  env_json="{\"Variables\":{\"BENCH_BUCKET\":\"${BENCH_BUCKET}\",\"BENCH_RUNTIME_LABEL\":\"${label}\",\"BENCH_FILE_COUNT\":\"${BENCH_FILE_COUNT}\",\"BENCH_FILE_SIZE_BYTES\":\"${BENCH_FILE_SIZE_BYTES}\",\"BENCH_PASSES\":\"${BENCH_PASSES}\"}}"

  echo "==> [${label}] creating/updating function ${fn} (standard aws lambda)"
  if aws lambda get-function --function-name "${fn}" >/dev/null 2>&1; then
    aws lambda update-function-code \
      --function-name "${fn}" --zip-file "fileb://${zip}" >/dev/null
    aws lambda wait function-updated --function-name "${fn}"
    aws lambda update-function-configuration \
      --function-name "${fn}" \
      --memory-size "${MEMORY_SIZE}" --timeout "${TIMEOUT}" \
      --layers "${LAYER_ARN}" \
      --environment "${env_json}" >/dev/null
    aws lambda wait function-updated --function-name "${fn}"
  else
    aws lambda create-function \
      --function-name "${fn}" \
      --runtime "provided.al2023" \
      --handler "bench-${client}.handler" \
      --role "${ROLE_ARN}" \
      --zip-file "fileb://${zip}" \
      --layers "${LAYER_ARN}" \
      --memory-size "${MEMORY_SIZE}" \
      --timeout "${TIMEOUT}" \
      --architectures "${ARCH}" \
      --environment "${env_json}" \
      --tenancy-config '{"TenantIsolationMode": "PER_TENANT"}' >/dev/null
    aws lambda wait function-active-v2 --function-name "${fn}"
  fi
}

deploy_layer_fn "bun"    "${FN_LAYER_BUN}"    "layer"
deploy_layer_fn "awssdk" "${FN_LAYER_AWSSDK}" "layer"

echo "Done. Layer functions: ${FN_LAYER_BUN}, ${FN_LAYER_AWSSDK}"
