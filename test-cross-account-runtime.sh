#!/bin/bash
# Experiment: can a Lambda function in account B use a customer-managed runtime
# (CMR) that lives in account A?
#
# This decides whether a single publicly shared Bun runtime is possible, or whether
# every user has to publish their own runtime. lambda-core has no sharing
# commands, but `aws lambda put-resource-policy` accepts runtime ARNs and the
# access-denied error names lambda:AssociateRuntimeAlias, so a resource policy
# on the runtime alias is the likely sharing mechanism. This script finds out.
#
# Functions are created WITHOUT tenancy config: it is an account-level feature that
# is not enabled everywhere, and it has nothing to do with runtime sharing.
#
# What it does:
#   1. Account A: ECR repo, runtime image build+push, runtime + version + alias.
#   2. Control:   function in account A on that runtime, invoked.
#                 (proves the runtime itself works, so a failure in B is about
#                 cross-account access and not about the image)
#   3. Test:      function in account B whose --runtime-config points at the
#                 runtime ARN in account A, then invoked. Tried three ways:
#                 no policy, a resource policy for account B on the runtime alias,
#                 and a resource policy with Principal "*" (public).
#   4. Cleanup:   removes everything it created in both accounts (unless KEEP=1).
#
# Usage:
#   PROFILE_A=<profile for account A> PROFILE_B=<profile for account B> \
#     ./test-cross-account-runtime.sh
#
# Optional env: AWS_REGION (default eu-west-1), KEEP=1 (skip cleanup).
#
# Exit codes:
#   0  cross-account works in at least one of the three ways
#   2  control passed but B could not use A's runtime in any way
#   1  anything else (setup failure, control failed, etc.)
set -euo pipefail
cd "$(dirname "$0")"

: "${PROFILE_A:?set PROFILE_A to the AWS profile of account A (runtime owner)}"
: "${PROFILE_B:?set PROFILE_B to the AWS profile of account B (runtime consumer)}"

REGION="${AWS_REGION:-eu-west-1}"
KEEP="${KEEP:-0}"
PREFIX="cmr-xacct-test"
# Deleted runtimes stay reserved (PENDING_DELETION) for 30 days, so every run
# needs a fresh runtime name.
RUNTIME_NAME="${PREFIX}-$(date +%s)"
REPO_NAME="${PREFIX}"
VERSION_NAME="test"
ALIAS_NAME="test"
ROLE_NAME="${PREFIX}-role"
FN_CONTROL="${PREFIX}-control"
FN_CROSS="${PREFIX}-cross"
WORKDIR="$(mktemp -d)"

# Never inherit a profile or region from the environment: every call is explicit.
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_DEFAULT_REGION
export AWS_REGION="${REGION}"

aws_a() { aws --profile "${PROFILE_A}" --region "${REGION}" "$@"; }
aws_b() { aws --profile "${PROFILE_B}" --region "${REGION}" "$@"; }

ACCOUNT_A="$(aws_a sts get-caller-identity --query Account --output text)"
ACCOUNT_B="$(aws_b sts get-caller-identity --query Account --output text)"
if [ "${ACCOUNT_A}" = "${ACCOUNT_B}" ]; then
  echo "PROFILE_A and PROFILE_B resolve to the same account (${ACCOUNT_A}); need two different accounts." >&2
  exit 1
fi

ECR_URI="${ACCOUNT_A}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}"
ROLE_ARN_A="arn:aws:iam::${ACCOUNT_A}:role/${ROLE_NAME}"
ROLE_ARN_B="arn:aws:iam::${ACCOUNT_B}:role/${ROLE_NAME}"

echo "Region:    ${REGION}"
echo "Account A: ${ACCOUNT_A} (runtime owner, profile ${PROFILE_A})"
echo "Account B: ${ACCOUNT_B} (consumer,      profile ${PROFILE_B})"

cleanup() {
  local status=$?
  rm -rf "${WORKDIR}"
  if [ "${KEEP}" = "1" ]; then
    echo "==> KEEP=1, leaving resources in place"
    return "${status}"
  fi
  echo "==> Cleanup"
  set +e
  aws_a lambda delete-function --function-name "${FN_CONTROL}" >/dev/null 2>&1
  aws_b lambda delete-function --function-name "${FN_CROSS}" >/dev/null 2>&1
  aws_a logs delete-log-group --log-group-name "/aws/lambda/${FN_CONTROL}" >/dev/null 2>&1
  aws_b logs delete-log-group --log-group-name "/aws/lambda/${FN_CROSS}" >/dev/null 2>&1
  aws_a lambda-core delete-runtime-alias --runtime-name "${RUNTIME_NAME}" --name "${ALIAS_NAME}" >/dev/null 2>&1
  aws_a lambda-core delete-runtime-version --runtime-name "${RUNTIME_NAME}" --name "${VERSION_NAME}" >/dev/null 2>&1
  aws_a lambda-core delete-runtime --runtime-name "${RUNTIME_NAME}" >/dev/null 2>&1
  aws_a ecr delete-repository --repository-name "${REPO_NAME}" --force >/dev/null 2>&1
  for profile_fn in aws_a aws_b; do
    "${profile_fn}" iam detach-role-policy --role-name "${ROLE_NAME}" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null 2>&1
    "${profile_fn}" iam delete-role --role-name "${ROLE_NAME}" >/dev/null 2>&1
  done
  return "${status}"
}
trap cleanup EXIT

ensure_role() {
  local profile_fn="$1"
  if "${profile_fn}" iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
    return 0
  fi
  "${profile_fn}" iam create-role --role-name "${ROLE_NAME}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": { "Service": "lambda.amazonaws.com" },
        "Action": "sts:AssumeRole"
      }]
    }' >/dev/null
  "${profile_fn}" iam attach-role-policy --role-name "${ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
}

echo "==> IAM roles in both accounts"
ensure_role aws_a
ensure_role aws_b
echo "    waiting 10s for role propagation"
sleep 10

echo "==> Account A: ECR repository ${REPO_NAME}"
if ! aws_a ecr describe-repositories --repository-names "${REPO_NAME}" >/dev/null 2>&1; then
  aws_a ecr create-repository --repository-name "${REPO_NAME}" >/dev/null
  aws_a ecr set-repository-policy --repository-name "${REPO_NAME}" --policy-text '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "LambdaReadAccess",
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": ["ecr:BatchGetImage", "ecr:DescribeImages", "ecr:GetDownloadUrlForLayer"]
    }]
  }' >/dev/null
fi

echo "==> Account A: build + push runtime image (arm64)"
aws_a ecr get-login-password \
  | docker login --username AWS --password-stdin "${ACCOUNT_A}.dkr.ecr.${REGION}.amazonaws.com"
docker buildx create --name cmrbuilder --driver docker-container --use 2>/dev/null \
  || docker buildx use cmrbuilder
# Same build flags as setup.sh (Docker v2 Schema 2, no provenance/sbom).
docker buildx build \
  --platform linux/arm64 \
  --tag "${ECR_URI}:${VERSION_NAME}" \
  --output type=image,oci-mediatypes=false \
  --provenance=false \
  --sbom=false \
  --push .

echo "==> Account A: runtime, version, alias"
aws_a lambda-core get-runtime --runtime-name "${RUNTIME_NAME}" >/dev/null 2>&1 \
  || aws_a lambda-core create-runtime --name "${RUNTIME_NAME}" \
       --description "cross-account experiment" --license-info "None" >/dev/null
RUNTIME_ARN="$(aws_a lambda-core get-runtime --runtime-name "${RUNTIME_NAME}" --query Arn --output text)"
echo "    RUNTIME_ARN=${RUNTIME_ARN}"
aws_a lambda-core create-runtime-version --runtime-name "${RUNTIME_NAME}" \
  --image-uri "${ECR_URI}:${VERSION_NAME}" --name "${VERSION_NAME}" >/dev/null
aws_a lambda-core wait runtime-version-active --runtime-name "${RUNTIME_NAME}" --name "${VERSION_NAME}"
aws_a lambda-core create-runtime-alias --runtime-name "${RUNTIME_NAME}" \
  --name "${ALIAS_NAME}" --runtime-version "${VERSION_NAME}" >/dev/null
aws_a lambda-core wait runtime-alias-active --runtime-name "${RUNTIME_NAME}" --name "${ALIAS_NAME}"

echo "==> Handler zip"
printf '%s\n' 'export const handler = async () => ({ ok: true, bun: Bun.version });' \
  > "${WORKDIR}/xacct.js"
(cd "${WORKDIR}" && zip -q xacct.zip xacct.js)

# create_and_invoke <profile_fn> <function name> <role arn>
# Prints the create error (if any) and returns 0 only if the function was created
# AND an invoke returned the handler's payload.
create_and_invoke() {
  local profile_fn="$1" fn="$2" role="$3"
  local create_out create_rc=0
  create_out="$("${profile_fn}" lambda create-function \
    --function-name "${fn}" \
    --runtime custom \
    --runtime-config "RuntimeArn=${RUNTIME_ARN},RuntimeAlias=${ALIAS_NAME}" \
    --handler xacct.handler \
    --role "${role}" \
    --zip-file "fileb://${WORKDIR}/xacct.zip" \
    --architectures arm64 \
    --memory-size 512 \
    --timeout 30 2>&1)" || create_rc=$?
  if [ "${create_rc}" -ne 0 ]; then
    echo "    create-function failed:"
    echo "${create_out}" | sed 's/^/      /'
    return 1
  fi
  "${profile_fn}" lambda wait function-active-v2 --function-name "${fn}" 2>&1 | sed 's/^/      /' || true

  local invoke_out invoke_rc=0
  invoke_out="$("${profile_fn}" lambda invoke \
    --function-name "${fn}" \
    --cli-binary-format raw-in-base64-out \
    --payload '{}' \
    --query '{FunctionError:FunctionError,StatusCode:StatusCode}' --output json \
    "${WORKDIR}/${fn}.out" 2>&1)" || invoke_rc=$?
  if [ "${invoke_rc}" -ne 0 ]; then
    echo "    invoke failed:"
    echo "${invoke_out}" | sed 's/^/      /'
    return 1
  fi
  echo "    invoke: ${invoke_out//$'\n'/ }  payload: $(cat "${WORKDIR}/${fn}.out")"
  grep -q '"ok":true' "${WORKDIR}/${fn}.out"
}

echo "==> Control: function in account A on A's runtime"
if ! create_and_invoke aws_a "${FN_CONTROL}" "${ROLE_ARN_A}"; then
  echo
  echo "VERDICT: control failed. The runtime/image itself does not work in account A,"
  echo "         so the cross-account result would be meaningless. Fix that first."
  exit 1
fi
echo "    control OK"

ALIAS_ARN="${RUNTIME_ARN}/alias/${ALIAS_NAME}"

# try_cross <label>: (re)creates the function in account B on A's runtime alias.
try_cross() {
  local label="$1"
  echo "==> Test (${label}): function in account B on ${ALIAS_ARN}"
  aws_b lambda delete-function --function-name "${FN_CROSS}" >/dev/null 2>&1 || true
  if create_and_invoke aws_b "${FN_CROSS}" "${ROLE_ARN_B}"; then
    echo "    RESULT (${label}): works"
    return 0
  fi
  echo "    RESULT (${label}): does not work"
  return 1
}

# put_policy <target arn> <principal json>: resource-based policy on one level of
# the runtime hierarchy (runtime, version or alias). The access-denied error named
# lambda:AssociateRuntimeAlias on the alias ARN, so that is what we grant. Returns
# non-zero (and prints the error) if PutResourcePolicy rejects the target.
put_policy() {
  local target="$1" principal="$2" out
  if out="$(aws_a lambda put-resource-policy --resource-arn "${target}" --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"xacct\",
      \"Effect\": \"Allow\",
      \"Principal\": ${principal},
      \"Action\": \"lambda:AssociateRuntimeAlias\",
      \"Resource\": [\"${target}\", \"${target}/*\"]
    }]
  }" 2>&1)"; then
    echo "    policy set on ${target}"
    return 0
  fi
  echo "    put-resource-policy failed on ${target}:"
  echo "${out}" | sed 's/^/      /'
  return 1
}

VERSION_ARN="${RUNTIME_ARN}/version/${VERSION_NAME}"
TARGETS=("${ALIAS_ARN}" "${RUNTIME_ARN}" "${VERSION_ARN}")
target_kind() {
  case "$1" in
    */alias/*) echo alias ;;
    */version/*) echo version ;;
    *) echo runtime ;;
  esac
}
declare -a RESULTS=()

if try_cross "no resource policy"; then
  RESULTS+=("no policy: works")
else
  RESULTS+=("no policy: fails")
  for principal_label in "account B" 'Principal "*"'; do
    if [ "${principal_label}" = "account B" ]; then
      principal="{\"AWS\": \"arn:aws:iam::${ACCOUNT_B}:root\"}"
    else
      principal='"*"'
    fi
    for target in "${TARGETS[@]}"; do
      kind="$(target_kind "${target}")"
      echo "==> Account A: policy for ${principal_label} on the ${kind}"
      if put_policy "${target}" "${principal}"; then
        if try_cross "${principal_label}, policy on ${kind}"; then
          RESULTS+=("${principal_label}, policy on ${kind}: works")
        else
          RESULTS+=("${principal_label}, policy on ${kind}: put ok, create fails")
        fi
      else
        RESULTS+=("${principal_label}, policy on ${kind}: put-resource-policy rejected")
      fi
    done
  done
fi

echo
echo "SUMMARY"
for line in "${RESULTS[@]}"; do echo "  ${line}"; done
echo "  (Account B may share an AWS Organization with A. If so, a \"*\" pass still"
echo "   needs a check from an account outside the organization.)"

for line in "${RESULTS[@]}"; do
  case "${line}" in *": works") exit 0 ;; esac
done
exit 2
