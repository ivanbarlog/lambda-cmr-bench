#!/bin/bash
# Run the benchmark against all deployed functions.
#
# For most functions (PER_TENANT tenancy):
#   - COLD rounds: each uses a fresh tenant-id (UUID) -> forces a new execution
#     environment -> cold start. The first invoke per tenant is the cold sample.
#   - WARM rounds: immediately re-invoke the SAME tenant-id -> warm start.
#
# For SnapStart functions (docker-snap): SnapStart is INCOMPATIBLE with tenancy,
# so cold (snapshot-restore) starts are forced with a CONCURRENT BURST instead of
# a fresh tenant (run_function_snapstart). Cold vs warm is classified from the
# REPORT "Restore Duration" (SnapStart) / "Init Duration" (normal) field rather
# than from the invoke position, so the classification is self-correcting.
#
# Captures per invoke:
#   - client wall-clock (ms) measured around the aws invoke call
#   - handler self-report (initToFirstInvokeMs, handlerMs, write/read ms) from payload
#   - CloudWatch REPORT line (Init/Restore Duration, Duration, Billed, Max Memory) via logs
#
# Output: results/<runtime>-<timestamp>.jsonl  (one JSON object per invoke)
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

COLD_ROUNDS="${COLD_ROUNDS:-10}"      # distinct cold environments per function
WARM_ROUNDS="${WARM_ROUNDS:-10}"      # warm invokes after each cold one (same tenant)
# COLD_BURST (SnapStart only): concurrent invokes per cold round used to force
# snapshot restores. Defaults to WARM_ROUNDS. Higher = more cold samples/round.

mkdir -p "${RESULTS_DIR}"
TS="$(date +%Y%m%d-%H%M%S)"

# Portable high-resolution wall clock in milliseconds.
# macOS /bin/bash is 3.2 (no EPOCHREALTIME) and `date` has no %N, so use python3.
now_ms() {
  python3 -c 'import time; print(time.time() * 1000)'
}

invoke_once() {
  # $1 = aws service (always "lambda"), $2 = function name,
  # $3 = tenant id (EMPTY string to omit --tenant-id, e.g. SnapStart functions
  #      which are incompatible with tenancy),
  # $4 = cold(1)/warm(0) INTENDED label, $5 = round, $6 = outfile
  # The emitted record's `cold` is derived from the observed log when possible
  # (Init Duration or Restore Duration present == cold); the intended flag is a
  # fallback only. This makes the SnapStart burst path (where we can't guarantee
  # which invoke lands cold) self-correcting.
  local svc="$1" fn="$2" tenant="$3" cold="$4" round="$5" outfile="$6"
  local payload out_json start end client_ms request_id

  payload=$(printf '{"fileCount":%s,"fileSizeBytes":%s,"passes":%s}' \
    "${BENCH_FILE_COUNT}" "${BENCH_FILE_SIZE_BYTES}" "${BENCH_PASSES}")

  out_json="$(mktemp)"
  start="$(now_ms)"
  # --log-type Tail returns the last 4KB of logs base64 in LogResult (incl. REPORT line)
  # svc is "lambda" for every function: CMR functions are standard Lambda
  # functions that reference a customer-managed runtime via --runtime-config.
  # Build the full arg array so we can conditionally include --tenant-id without
  # expanding an empty array (bash 3.2 on macOS errors on "${arr[@]}" when empty
  # under set -u). SnapStart functions pass an empty tenant -> no --tenant-id.
  local invoke_args=(--function-name "${fn}")
  if [ -n "${tenant}" ]; then
    invoke_args+=(--tenant-id "${tenant}")
  fi
  invoke_args+=(
    --payload "$(echo -n "${payload}" | base64 | tr -d '\n')"
    --log-type Tail
    --query '{Log:LogResult,FunctionError:FunctionError}'
    --output json
    "${out_json}"
  )
  local meta
  meta=$(aws "${svc}" invoke "${invoke_args[@]}")
  end="$(now_ms)"
  client_ms=$(awk "BEGIN { printf \"%.3f\", (${end} - ${start}) }")

  local logb64 fn_err resp init_dur dur billed maxmem restore billed_restore metrics
  logb64=$(echo "${meta}" | bun -e 'const j=JSON.parse(await Bun.stdin.text()); process.stdout.write(j.Log ?? "")')
  fn_err=$(echo "${meta}" | bun -e 'const j=JSON.parse(await Bun.stdin.text()); process.stdout.write(j.FunctionError ?? "")')

  # Two log formats to support:
  #   1. Bun customer-managed runtime + provided.al2023 layer: STRUCTURED JSON log
  #      events (one JSON object per line); metrics live in the
  #      {"type":"platform.report","record":{"metrics":{...}}} event.
  #   2. Official nodejs24.x managed runtime: the classic plain-text
  #      "REPORT RequestId: ... Init Duration: N ms  Duration: N ms  Billed
  #      Duration: N ms  Max Memory Used: N MB" line.
  # SnapStart functions additionally report Restore Duration / Billed Restore
  # Duration on a cold (snapshot-restore) invoke, and OMIT Init Duration from the
  # REPORT (init happened at publish time). So "restore present" == cold for the
  # snap variants. We parse restore from both the JSON metrics and the plain-text
  # REPORT line. Emit six tab-separated fields.
  metrics=$(echo "${logb64}" | base64 -d 2>/dev/null | bun -e '
    const text = await Bun.stdin.text();
    let m = null;
    for (const line of text.split("\n")) {
      const trimmed = line.trim();
      if (trimmed === "") continue;
      let event;
      try { event = JSON.parse(trimmed); } catch { continue; }
      if (event?.type === "platform.report" && event.record?.metrics != null) {
        m = event.record.metrics;
      }
    }
    if (m == null) {
      // Fall back to the classic plain-text REPORT line (managed Node runtime,
      // and the plain-text REPORT emitted for SnapStart restores).
      const grab = (re) => {
        const match = text.match(re);
        return match == null ? null : Number(match[1]);
      };
      const init = grab(/Init Duration:\s*([\d.]+)\s*ms/);
      // Plain invocation Duration: must NOT match "Init Duration",
      // "Billed Duration", "Restore Duration", or "Billed Restore Duration".
      // Require that "Duration" is not immediately preceded by those words.
      const dur = grab(/(?<!Init )(?<!Billed )(?<!Restore )Duration:\s*([\d.]+)\s*ms/);
      const billed = grab(/Billed Duration:\s*([\d.]+)\s*ms/);
      const maxmem = grab(/Max Memory Used:\s*([\d.]+)\s*MB/);
      const restore = grab(/(?<!Billed )Restore Duration:\s*([\d.]+)\s*ms/);
      const billedRestore = grab(/Billed Restore Duration:\s*([\d.]+)\s*ms/);
      if (dur != null || init != null || restore != null) {
        m = {
          initDurationMs: init, durationMs: dur, billedDurationMs: billed,
          maxMemoryUsedMB: maxmem, restoreDurationMs: restore, billedRestoreDurationMs: billedRestore,
        };
      }
    }
    const pick = (value) => (value == null ? "" : String(value));
    process.stdout.write(
      [
        pick(m?.initDurationMs), pick(m?.durationMs), pick(m?.billedDurationMs),
        pick(m?.maxMemoryUsedMB), pick(m?.restoreDurationMs), pick(m?.billedRestoreDurationMs),
      ].join("\t"),
    );
  ' || echo -e "\t\t\t\t\t")
  init_dur=$(echo "${metrics}" | cut -f1)
  dur=$(echo "${metrics}" | cut -f2)
  billed=$(echo "${metrics}" | cut -f3)
  maxmem=$(echo "${metrics}" | cut -f4)
  restore=$(echo "${metrics}" | cut -f5)
  billed_restore=$(echo "${metrics}" | cut -f6)

  resp=$(cat "${out_json}")
  rm -f "${out_json}"

  # Emit one JSONL record combining client + CloudWatch + handler payload.
  bun -e '
    const [fn, tenant, coldIntended, round, clientMs, initDur, dur, billed, maxmem, restore, billedRestore, fnErr] = process.argv.slice(1);
    let handler = null;
    try { handler = JSON.parse(await Bun.stdin.text()); } catch {}
    const num = (value) => (value === "" ? null : Number(value));
    const initDurationMs = num(initDur);
    const restoreDurationMs = num(restore);
    // Observed cold: a REPORT with Init Duration (normal cold) or Restore Duration
    // (SnapStart cold). If the log yielded neither signal, fall back to the
    // handler self-report (invocationCount===1), then the intended flag.
    let cold;
    if (initDurationMs != null || restoreDurationMs != null) {
      cold = true;
    } else if (dur !== "" || billed !== "") {
      // We have a REPORT but no init/restore -> genuinely warm.
      cold = false;
    } else if (handler?.coldStart != null) {
      cold = handler.coldStart === true;
    } else {
      cold = coldIntended === "1";
    }
    const rec = {
      fn, tenant: tenant || null,
      cold,
      coldIntended: coldIntended === "1",
      round: Number(round),
      clientMs: Number(clientMs),
      initDurationMs,
      durationMs: num(dur),
      billedMs: num(billed),
      maxMemoryMB: num(maxmem),
      restoreMs: restoreDurationMs,
      billedRestoreMs: num(billedRestore),
      functionError: fnErr || null,
      handler,
    };
    console.log(JSON.stringify(rec));
  ' "${fn}" "${tenant}" "${cold}" "${round}" "${client_ms}" \
    "${init_dur}" "${dur}" "${billed}" "${maxmem}" "${restore}" "${billed_restore}" "${fn_err}" \
    < <(printf '%s' "${resp}") >> "${outfile}"

  if [ -n "${fn_err}" ]; then
    local phase; [ "${cold}" = "1" ] && phase="cold" || phase="warm"
    echo "    !! FunctionError on ${fn} (${phase}): ${fn_err}" >&2
    echo "       response: ${resp}" >&2
  fi
}

run_function() {
  local svc="$1" fn="$2" label="$3"
  local outfile="${RESULTS_DIR}/${label}-${TS}.jsonl"
  : > "${outfile}"
  echo "==> Benchmarking ${label} function: ${fn} (aws ${svc})"
  echo "    cold rounds=${COLD_ROUNDS} warm rounds=${WARM_ROUNDS} files=${BENCH_FILE_COUNT} size=${BENCH_FILE_SIZE_BYTES}B passes=${BENCH_PASSES}"

  for r in $(seq 1 "${COLD_ROUNDS}"); do
    local tenant
    tenant=$(bun -e 'console.log(Bun.randomUUIDv7())')
    echo "    round ${r}/${COLD_ROUNDS} tenant=${tenant}"
    # first invoke on a brand-new tenant -> cold
    invoke_once "${svc}" "${fn}" "${tenant}" 1 "${r}" "${outfile}"
    # subsequent invokes on same tenant -> warm
    for w in $(seq 1 "${WARM_ROUNDS}"); do
      invoke_once "${svc}" "${fn}" "${tenant}" 0 "${r}" "${outfile}"
    done
  done
  echo "    -> ${outfile}"
}

# SnapStart run path. SnapStart functions can't use tenancy, so we force cold
# (snapshot-restore) starts with a CONCURRENT BURST: firing several invokes at
# once makes Lambda scale out to multiple fresh execution environments, each of
# which restores from the snapshot (a cold start). Warm samples then come from
# serial re-invokes that reuse a warmed environment. Cold vs warm is classified
# from the REPORT "Restore Duration" (see invoke_once), so a burst invoke that
# happens to reuse an environment is simply recorded as warm — no miscount.
#   $1 = qualified function name (e.g. fn:alias)   $2 = runtime label
#   Tenant is empty (omit --tenant-id).
run_function_snapstart() {
  local fn="$1" label="$2"
  local outfile="${RESULTS_DIR}/${label}-${TS}.jsonl"
  local burst="${COLD_BURST:-${WARM_ROUNDS}}"   # concurrent invokes per cold round
  : > "${outfile}"
  echo "==> Benchmarking ${label} function: ${fn} (aws lambda, SnapStart, no tenancy)"
  echo "    cold rounds=${COLD_ROUNDS} burst=${burst} warm rounds=${WARM_ROUNDS} files=${BENCH_FILE_COUNT} size=${BENCH_FILE_SIZE_BYTES}B passes=${BENCH_PASSES}"

  for r in $(seq 1 "${COLD_ROUNDS}"); do
    echo "    round ${r}/${COLD_ROUNDS} (burst of ${burst} to force snapshot restores)"
    # Concurrent burst -> forces fresh restored (cold) environments. Run in the
    # background and wait; each writes its own record to the shared outfile
    # (append is atomic for these small lines).
    local pids=()
    for _b in $(seq 1 "${burst}"); do
      invoke_once "lambda" "${fn}" "" 1 "${r}" "${outfile}" &
      pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "${pid}"; done
    # Warm: serial re-invokes reuse a now-warm environment.
    for _w in $(seq 1 "${WARM_ROUNDS}"); do
      invoke_once "lambda" "${fn}" "" 0 "${r}" "${outfile}"
    done
  done
  echo "    -> ${outfile}"
}

# Matrix: {cmr,layer} x {bun,awssdk}.
run_function "lambda"     "${FN_CMR_BUN}"      "cmr-bun"
run_function "lambda"     "${FN_CMR_AWSSDK}"   "cmr-awssdk"
run_function "lambda"     "${FN_LAYER_BUN}"    "layer-bun"
run_function "lambda"     "${FN_LAYER_AWSSDK}" "layer-awssdk"

# "bun in docker": container-image Lambdas (standard aws lambda), same Bun runtime.
#   docker      = no SnapStart, invoked on $LATEST (like the other variants).
#   docker-snap = SnapStart, invoked via the ${DOCKER_SNAP_ALIAS} alias (SnapStart
#                 only applies to published versions). Deployed by deploy-docker.sh;
#                 each is skipped here if its function isn't deployed.
if aws lambda get-function --function-name "${FN_DOCKER_BUN}" >/dev/null 2>&1; then
  run_function "lambda" "${FN_DOCKER_BUN}"    "docker-bun"
  run_function "lambda" "${FN_DOCKER_AWSSDK}" "docker-awssdk"
else
  echo "==> Skipping docker variants (not deployed — run ./deploy-docker.sh)"
fi
if aws lambda get-alias --function-name "${FN_DOCKER_BUN_SNAP}" --name "${DOCKER_SNAP_ALIAS}" >/dev/null 2>&1; then
  run_function_snapstart "${FN_DOCKER_BUN_SNAP}:${DOCKER_SNAP_ALIAS}"    "docker-snap-bun"
  run_function_snapstart "${FN_DOCKER_AWSSDK_SNAP}:${DOCKER_SNAP_ALIAS}" "docker-snap-awssdk"
else
  echo "==> Skipping docker-snap variants (not deployed — run ./deploy-docker.sh)"
fi

# Node baseline: official nodejs24.x managed runtime with aws-sdk bundled.
# Standard Lambda service. Deployed by deploy-node.sh; skipped here if absent.
if aws lambda get-function --function-name "${FN_NODE_AWSSDK}" >/dev/null 2>&1; then
  run_function "lambda"   "${FN_NODE_AWSSDK}"  "node-awssdk"
else
  echo "==> Skipping ${FN_NODE_AWSSDK} (not deployed — run ./deploy-node.sh)"
fi

echo
echo "Raw results written to ${RESULTS_DIR}/*-${TS}.jsonl"
echo "Now run:  bun compare.ts ${RESULTS_DIR}/*-${TS}.jsonl"
