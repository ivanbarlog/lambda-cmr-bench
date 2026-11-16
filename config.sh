#!/bin/bash
# Shared configuration for the Lambda customer-managed runtime (CMR) Bun benchmark.
# Source this from the other scripts:  source ./config.sh
set -euo pipefail

# --- AWS ---
export AWS_REGION="${AWS_REGION:-eu-west-1}"
# AWS_PROFILE is optional: when unset, the default AWS CLI credential chain applies.
# The account ID is resolved from the active credentials unless ACCOUNT_ID is set.
if [ -z "${ACCOUNT_ID:-}" ]; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
fi
export ACCOUNT_ID

# --- Shared infra ---
export BENCH_BUCKET="${BENCH_BUCKET:-cmr-bun-bench-${ACCOUNT_ID}}"
export ROLE_NAME="${ROLE_NAME:-cmr-bun-bench-role}"
export ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

# --- Runtime / image (CMR side) ---
export RUNTIME_NAME="${RUNTIME_NAME:-bun-runtime}"
export REPO_NAME="${REPO_NAME:-bun-runtime}"
export REPO_REGION="${AWS_REGION}"
export ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REPO_REGION}.amazonaws.com/${REPO_NAME}"
export IMAGE_TAG="${IMAGE_TAG:-bench}"
export RUNTIME_VERSION="${RUNTIME_VERSION:-bench}"
export RUNTIME_ALIAS="${RUNTIME_ALIAS:-bench}"

# --- Layer side ---
# The Bun runtime layer zip ships inside the installed @beesolve/lambda-bun-runtime
# package (dist/bun-lambda-layer-<bunVersion>.zip). Resolve it from node_modules
# rather than a relative path so `bun install` is the single source of truth.
# Override LAYER_ZIP to point elsewhere if needed.
export LAYER_NAME="${LAYER_NAME:-bun-runtime-layer}"
_layer_pkg_dist="node_modules/@beesolve/lambda-bun-runtime/dist"
if [ -z "${LAYER_ZIP:-}" ]; then
  # Pick the (single) layer zip shipped in the package.
  LAYER_ZIP="$(ls "${_layer_pkg_dist}"/bun-lambda-layer-*.zip 2>/dev/null | head -1 || true)"
fi
export LAYER_ZIP

# --- Functions (4-way Bun matrix: {cmr,layer} x {bun,awssdk}) ---
export FN_CMR_BUN="${FN_CMR_BUN:-bun-bench-cmr-bun}"
export FN_CMR_AWSSDK="${FN_CMR_AWSSDK:-bun-bench-cmr-awssdk}"
export FN_LAYER_BUN="${FN_LAYER_BUN:-bun-bench-layer-bun}"
export FN_LAYER_AWSSDK="${FN_LAYER_AWSSDK:-bun-bench-layer-awssdk}"

# --- Docker (container-image Lambda) variants: {bun,awssdk} x {no-snap,snap} ---
# A real container-image function (--package-type Image) running the same Bun
# runtime as the CMR/layer variants, but deployed via the STANDARD aws lambda
# service so it can opt into SnapStart. Each S3 client x SnapStart combination is
# its own function (SnapStart applies to published versions, so the with/without
# comparison needs separate functions rather than one function's $LATEST vs alias).
#   Image repo is separate from the CMR runtime repo (REPO_NAME): these are whole
#   FUNCTION images, not a CMR runtime image, and can be plain OCI.
export FN_DOCKER_BUN="${FN_DOCKER_BUN:-bun-bench-docker-bun}"
export FN_DOCKER_AWSSDK="${FN_DOCKER_AWSSDK:-bun-bench-docker-awssdk}"
export FN_DOCKER_BUN_SNAP="${FN_DOCKER_BUN_SNAP:-bun-bench-docker-bun-snap}"
export FN_DOCKER_AWSSDK_SNAP="${FN_DOCKER_AWSSDK_SNAP:-bun-bench-docker-awssdk-snap}"
# Alias name published for the SnapStart functions (SnapStart only applies to
# published versions; run-benchmark.sh invokes this alias for the snap variants).
export DOCKER_SNAP_ALIAS="${DOCKER_SNAP_ALIAS:-snap}"
# Function-image ECR repo + per-variant tags (bun / awssdk).
export FN_REPO_NAME="${FN_REPO_NAME:-bun-bench-function}"
export FN_ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REPO_REGION}.amazonaws.com/${FN_REPO_NAME}"
export FN_IMAGE_TAG_BUN="${FN_IMAGE_TAG_BUN:-bun}"
export FN_IMAGE_TAG_AWSSDK="${FN_IMAGE_TAG_AWSSDK:-awssdk}"

# --- Node baseline (official AWS managed runtime, aws-sdk bundled) ---
# A 5th function outside the Bun matrix: the official nodejs24.x managed runtime
# with @aws-sdk/client-s3 bundled into the deployment zip (rather than relying on
# whatever SDK the runtime preinstalls). Gives a node/aws-sdk data point to
# compare against layer/aws-sdk and cmr/aws-sdk.
export FN_NODE_AWSSDK="${FN_NODE_AWSSDK:-bun-bench-node-awssdk}"
export NODE_RUNTIME="${NODE_RUNTIME:-nodejs24.x}"
export ARCH="${ARCH:-arm64}"          # arm64 | x86_64 (must match image + layer)
export MEMORY_SIZE="${MEMORY_SIZE:-1024}"
export TIMEOUT="${TIMEOUT:-60}"

# --- Workload defaults (overridable per invoke via event payload) ---
export BENCH_FILE_COUNT="${BENCH_FILE_COUNT:-100}"
export BENCH_FILE_SIZE_BYTES="${BENCH_FILE_SIZE_BYTES:-1024}"
export BENCH_PASSES="${BENCH_PASSES:-1}"

# --- Results ---
export RESULTS_DIR="${RESULTS_DIR:-./results}"

# Docker platform string derived from ARCH (x86_64 -> amd64)
export DOCKER_PLATFORM="linux/${ARCH/x86_64/amd64}"

# Build a handler zip for the given S3 client variant.
#   $1 = client (bun | awssdk | node)   -> uses handler-<client>.ts
#   $2 = output zip path
# The bundle target follows the client: the `node` variant targets the official
# Node managed runtime (--target=node); all Bun variants target Bun.
# Records the minified bundle byte size into ${RESULTS_DIR}/bundle-sizes.json.
build_handler_zip() {
  local client="$1" zip_path="$2"
  local entry="handler-${client}.ts"

  # `node` -> official nodejs24.x managed runtime; everything else -> Bun.
  local target="bun"
  [ "${client}" = "node" ] && target="node"

  # The bundle uses ESM (import/import.meta). Bun's own runtime loads it as ESM
  # regardless of extension, but the official Node managed runtime uses the CJS
  # loader for `.js` unless package.json says otherwise — which throws
  # "Cannot use import statement outside a module". Emit `.mjs` for the node
  # variant so Node always treats it as ESM. The Lambda handler string
  # (`bench-node.handler`) resolves `bench-node.mjs` automatically.
  local ext="js"
  [ "${target}" = "node" ] && ext="mjs"
  local jsfile="/tmp/bench-${client}.${ext}"

  # Safeguard: never bundle the CDK construct package into a handler. The handlers
  # don't import it, but marking it external guarantees it can't leak into the zip.
  bun build "${entry}" --target="${target}" --minify \
    --external @beesolve/lambda-bun-runtime \
    --outfile "${jsfile}"
  local bytes
  bytes=$(wc -c < "${jsfile}" | tr -d ' ')

  ( cd "$(dirname "${jsfile}")" && rm -f "$(basename "${zip_path}")" \
      && zip -j "${zip_path}" "$(basename "${jsfile}")" >/dev/null )

  mkdir -p "${RESULTS_DIR}"
  local sizes="${RESULTS_DIR}/bundle-sizes.json"
  [ -f "${sizes}" ] || echo "{}" > "${sizes}"
  # Merge this client's size into the JSON map.
  bun -e "
    const f = process.argv[1];
    const client = process.argv[2];
    const bytes = Number(process.argv[3]);
    const data = JSON.parse(await Bun.file(f).text());
    data[client] = bytes;
    await Bun.write(f, JSON.stringify(data, null, 2));
  " "${sizes}" "${client}" "${bytes}"

  echo "    ${entry} -> ${zip_path} (minified JS ${bytes} bytes)"
}
