#!/usr/bin/env bun
// Aggregate benchmark JSONL files and print a cold-vs-warm comparison across the
// delivery x S3-client matrix: {cmr, layer, docker, docker-snap} delivery x
// {bun, aws-sdk} S3 client, plus the node/aws-sdk baseline. The docker variants
// are container-image Lambdas; docker-snap adds SnapStart.
//
// Usage: bun compare.ts results/*-<ts>.jsonl
//   (optionally reads bundle-sizes.json from the input directory or results/ for the bundle-size table)

import { dirname, join } from "node:path";

interface HandlerPayload {
  runtime?: string; // cmr | layer | docker | docker-snap
  s3client?: string; // bun | aws-sdk
  initToFirstInvokeMs?: number;
  handlerMs?: number;
  writeMsTotal?: number;
  readMsTotal?: number;
  coldStart?: boolean;
}

interface Record {
  fn: string;
  tenant: string | null;
  cold: boolean;
  coldIntended?: boolean;
  round: number;
  clientMs: number;
  initDurationMs: number | null;
  durationMs: number | null;
  billedMs: number | null;
  maxMemoryMB: number | null;
  restoreMs: number | null;
  billedRestoreMs: number | null;
  functionError: string | null;
  handler: HandlerPayload | null;
}

interface Stats {
  count: number;
  mean: number;
  p50: number;
  p95: number;
  min: number;
  max: number;
}

const files = process.argv.slice(2);
if (files.length === 0) {
  console.error("Usage: bun compare.ts <results.jsonl> [more.jsonl ...]");
  process.exit(1);
}

const records: Record[] = [];
for (const file of files) {
  const text = await Bun.file(file).text();
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (trimmed === "") continue;
    records.push(JSON.parse(trimmed) as Record);
  }
}

const errors = records.filter((record) => record.functionError != null);
if (errors.length > 0) {
  console.log(`\n⚠️  ${errors.length} invoke(s) returned a FunctionError — excluded from stats.\n`);
}
const ok = records.filter((record) => record.functionError == null);

const variants = [...new Set(ok.map(variantOf))].sort();

console.log(`\nSamples: ${ok.length} ok / ${records.length} total across ${variants.length} variant(s):`);
console.log(`  ${variants.join(", ")}\n`);

await printBundleSizes();

for (const metric of ["initDurationMs", "restoreMs", "durationMs", "clientMs", "billedMs"] as const) {
  printMetric(metric);
}
printColdStartMetric();
printHandlerMetric("initToFirstInvokeMs", (payload) => payload.initToFirstInvokeMs, "cold");
printHandlerMetric("handlerMs", (payload) => payload.handlerMs, "all");
printHandlerMetric("writeMsTotal", (payload) => payload.writeMsTotal, "all");
printHandlerMetric("readMsTotal", (payload) => payload.readMsTotal, "all");

printVerdicts();

function runtimeOf(record: Record): string {
  return record.handler?.runtime ?? "?";
}
function clientOf(record: Record): string {
  return record.handler?.s3client ?? "?";
}
function variantOf(record: Record): string {
  return `${runtimeOf(record)}/${clientOf(record)}`;
}

function stats(values: number[]): Stats | null {
  const clean = values.filter((value) => value != null && Number.isFinite(value));
  if (clean.length === 0) return null;
  const sorted = [...clean].sort((a, b) => a - b);
  const sum = sorted.reduce((acc, value) => acc + value, 0);
  return {
    count: sorted.length,
    mean: sum / sorted.length,
    p50: percentile(sorted, 50),
    p95: percentile(sorted, 95),
    min: sorted[0]!,
    max: sorted[sorted.length - 1]!,
  };
}

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 1) return sorted[0]!;
  const rank = (p / 100) * (sorted.length - 1);
  const low = Math.floor(rank);
  const high = Math.ceil(rank);
  if (low === high) return sorted[low]!;
  return sorted[low]! + (sorted[high]! - sorted[low]!) * (rank - low);
}

function fmt(value: number | undefined): string {
  return value == null ? "—" : value.toFixed(1).padStart(9);
}

async function printBundleSizes(): Promise<void> {
  // Prefer bundle-sizes.json next to the first input file (data/<run>/), then results/.
  const candidates = [join(dirname(files[0]), "bundle-sizes.json"), "results/bundle-sizes.json"];
  let file = Bun.file(candidates[0]);
  if (!(await file.exists())) file = Bun.file(candidates[1]);
  if (!(await file.exists())) return;
  const sizes = JSON.parse(await file.text()) as Record<string, number>;
  console.log("### Bundle size (minified handler JS, before zip)");
  console.log(`${"s3client".padEnd(10)} ${"bytes".padStart(10)} ${"KB".padStart(9)}`);
  for (const [client, bytes] of Object.entries(sizes)) {
    console.log(`${client.padEnd(10)} ${String(bytes).padStart(10)} ${(bytes / 1024).toFixed(1).padStart(9)}`);
  }
  console.log();
}

function subset(variant: string, phase: "cold" | "warm"): Record[] {
  return ok.filter(
    (record) => variantOf(record) === variant && record.cold === (phase === "cold"),
  );
}

// Total cold-start cost, uniform across normal (init) and SnapStart (restore)
// functions: (restore OR init) + invocation duration. AWS defines the SnapStart
// cold start as Restore Duration + Duration; for a normal cold it's Init
// Duration + Duration. Returns null if the record isn't a usable cold sample.
function coldStartMsOf(record: Record): number | null {
  if (!record.cold) return null;
  const startup = record.restoreMs ?? record.initDurationMs;
  if (startup == null || record.durationMs == null) return null;
  return startup + record.durationMs;
}

function printColdStartMetric(): void {
  console.log(`\n### coldStartMs (cold only = (Restore|Init) + Duration)`);
  console.log(`${"variant".padEnd(18)} ${"phase".padEnd(6)} ${"n".padStart(4)} ${"mean".padStart(9)} ${"p50".padStart(9)} ${"p95".padStart(9)} ${"min".padStart(9)} ${"max".padStart(9)}`);
  for (const variant of variants) {
    const values = subset(variant, "cold")
      .map((record) => coldStartMsOf(record))
      .filter((value): value is number => value != null);
    const stat = stats(values);
    if (stat == null) continue;
    console.log(
      `${variant.padEnd(18)} ${"cold".padEnd(6)} ${String(stat.count).padStart(4)} ${fmt(stat.mean)} ${fmt(stat.p50)} ${fmt(stat.p95)} ${fmt(stat.min)} ${fmt(stat.max)}`,
    );
  }
}

function printMetric(metric: "initDurationMs" | "restoreMs" | "durationMs" | "clientMs" | "billedMs"): void {
  const isColdOnly = metric === "initDurationMs" || metric === "restoreMs";
  const phases: Array<"cold" | "warm"> = isColdOnly ? ["cold"] : ["cold", "warm"];
  console.log(`\n### ${metric}${isColdOnly ? " (cold only)" : ""}`);
  console.log(`${"variant".padEnd(18)} ${"phase".padEnd(6)} ${"n".padStart(4)} ${"mean".padStart(9)} ${"p50".padStart(9)} ${"p95".padStart(9)} ${"min".padStart(9)} ${"max".padStart(9)}`);
  for (const variant of variants) {
    for (const phase of phases) {
      const stat = stats(subset(variant, phase).map((record) => record[metric] as number));
      if (stat == null) continue;
      console.log(
        `${variant.padEnd(18)} ${phase.padEnd(6)} ${String(stat.count).padStart(4)} ${fmt(stat.mean)} ${fmt(stat.p50)} ${fmt(stat.p95)} ${fmt(stat.min)} ${fmt(stat.max)}`,
      );
    }
  }
}

function printHandlerMetric(
  name: string,
  pick: (payload: HandlerPayload) => number | undefined,
  scope: "cold" | "all",
): void {
  console.log(`\n### handler.${name}${scope === "cold" ? " (cold only)" : ""}`);
  console.log(`${"variant".padEnd(18)} ${"phase".padEnd(6)} ${"n".padStart(4)} ${"mean".padStart(9)} ${"p50".padStart(9)} ${"p95".padStart(9)}`);
  const phases: Array<"cold" | "warm"> = scope === "cold" ? ["cold"] : ["cold", "warm"];
  for (const variant of variants) {
    for (const phase of phases) {
      const rows = subset(variant, phase).filter((record) => record.handler != null);
      const stat = stats(rows.map((record) => pick(record.handler!) ?? Number.NaN));
      if (stat == null) continue;
      console.log(
        `${variant.padEnd(18)} ${phase.padEnd(6)} ${String(stat.count).padStart(4)} ${fmt(stat.mean)} ${fmt(stat.p50)} ${fmt(stat.p95)}`,
      );
    }
  }
}

function p50Of(variant: string, metric: "initDurationMs" | "durationMs", phase: "cold" | "warm"): number | null {
  const stat = stats(subset(variant, phase).map((record) => record[metric] as number));
  return stat?.p50 ?? null;
}

function p50ColdStartOf(variant: string): number | null {
  const values = subset(variant, "cold")
    .map((record) => coldStartMsOf(record))
    .filter((value): value is number => value != null);
  return stats(values)?.p50 ?? null;
}

// Compare total cold-start cost (Restore|Init + Duration) between two variants.
// Use this instead of comparePair("initDurationMs", ...) whenever a SnapStart
// variant is involved, since SnapStart reports Restore Duration (not Init).
function compareColdStart(a: string, b: string): void {
  const pa = p50ColdStartOf(a);
  const pb = p50ColdStartOf(b);
  if (pa == null || pb == null) {
    const missing = [pa == null ? a : null, pb == null ? b : null].filter((value) => value != null);
    console.log(`  coldStartMs (cold): no data for ${missing.join(", ")} (all invokes errored?)`);
    return;
  }
  const faster = pa < pb ? a : b;
  const ratio = Math.max(pa, pb) / Math.min(pa, pb);
  console.log(
    `  coldStartMs (cold) p50: ${a}=${pa.toFixed(1)}ms vs ${b}=${pb.toFixed(1)}ms -> ${faster} faster by ${((ratio - 1) * 100).toFixed(1)}%`,
  );
}

function comparePair(a: string, b: string, metric: "initDurationMs" | "durationMs", phase: "cold" | "warm"): void {
  const pa = p50Of(a, metric, phase);
  const pb = p50Of(b, metric, phase);
  if (pa == null || pb == null) {
    const missing = [pa == null ? a : null, pb == null ? b : null].filter((value) => value != null);
    console.log(`  ${metric} (${phase}): no data for ${missing.join(", ")} (all invokes errored?)`);
    return;
  }
  const faster = pa < pb ? a : b;
  const ratio = Math.max(pa, pb) / Math.min(pa, pb);
  console.log(
    `  ${metric} (${phase}) p50: ${a}=${pa.toFixed(1)}ms vs ${b}=${pb.toFixed(1)}ms -> ${faster} faster by ${((ratio - 1) * 100).toFixed(1)}%`,
  );
}

function printVerdicts(): void {
  // Also surface variants that errored entirely (present in raw records but with
  // zero OK samples) so an empty verdict is never silent.
  const errored = [...new Set(errors.map((record) => variantOf(record)))].filter(
    (variant) => !variants.includes(variant),
  );
  if (errored.length > 0) {
    console.log(`\n### Variants with NO successful samples (all invokes errored): ${errored.join(", ")}`);
    console.log(`   (check CloudWatch logs — comparisons involving these show "no data")`);
  }

  console.log(`\n### Verdicts`);

  // 1. Delivery mechanism (cmr vs layer), holding S3 client constant.
  console.log(`\n  -- Delivery: CMR image vs Lambda layer (same S3 client) --`);
  for (const client of ["bun", "aws-sdk"]) {
    comparePair(`cmr/${client}`, `layer/${client}`, "initDurationMs", "cold");
    comparePair(`cmr/${client}`, `layer/${client}`, "durationMs", "warm");
  }

  // 2. S3 client (bun vs aws-sdk), holding delivery constant.
  console.log(`\n  -- S3 client: Bun native vs AWS SDK (same delivery) --`);
  for (const runtime of ["cmr", "layer"]) {
    comparePair(`${runtime}/bun`, `${runtime}/aws-sdk`, "initDurationMs", "cold"); // SDK bundle cost shows here
    comparePair(`${runtime}/bun`, `${runtime}/aws-sdk`, "durationMs", "warm"); // pure client throughput
  }

  // 3. Node managed-runtime baseline (aws-sdk bundled) vs the Bun aws-sdk
  //    variants. Only emitted when node/aws-sdk samples are present.
  if (variants.includes("node/aws-sdk")) {
    console.log(`\n  -- Runtime: official nodejs24.x vs Bun (same S3 client: aws-sdk) --`);
    comparePair("node/aws-sdk", "cmr/aws-sdk", "initDurationMs", "cold");
    comparePair("node/aws-sdk", "cmr/aws-sdk", "durationMs", "warm");
    comparePair("node/aws-sdk", "layer/aws-sdk", "initDurationMs", "cold");
    comparePair("node/aws-sdk", "layer/aws-sdk", "durationMs", "warm");
  }

  // 4. SnapStart effect on the container-image (docker) variants: docker-snap vs
  //    docker, same S3 client. Cold start is where SnapStart should win big (it
  //    restores from a snapshot instead of re-initializing). SnapStart reports
  //    Restore Duration (not Init), so compare the combined cold-start cost
  //    (Restore|Init + Duration). Only emitted when docker-snap samples present.
  if (variants.some((variant) => variant.startsWith("docker-snap/"))) {
    console.log(`\n  -- SnapStart: docker + SnapStart vs docker without (same S3 client) --`);
    for (const client of ["bun", "aws-sdk"]) {
      compareColdStart(`docker-snap/${client}`, `docker/${client}`);
      comparePair(`docker-snap/${client}`, `docker/${client}`, "durationMs", "warm");
    }
  }

  // 5. Container image (docker, no SnapStart) vs the other Bun delivery
  //    mechanisms (cmr, layer), same S3 client. Compares total cold-start cost so
  //    it stays comparable even if a variant reports restore instead of init.
  //    Only emitted when the docker samples are present.
  if (variants.some((variant) => variant.startsWith("docker/"))) {
    console.log(`\n  -- Delivery: container image (docker) vs CMR / layer (same S3 client) --`);
    for (const client of ["bun", "aws-sdk"]) {
      compareColdStart(`docker/${client}`, `cmr/${client}`);
      compareColdStart(`docker/${client}`, `layer/${client}`);
    }
  }

  console.log();
}
