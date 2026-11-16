// Node.js 24 managed-runtime benchmark handler.
//
// This is the odd one out in the matrix: every other variant runs the Bun
// runtime (via CMR image or layer) and shares core.ts, which leans on Bun-only
// APIs (Bun.randomUUIDv7, Bun.version, Bun.file). This handler targets the
// OFFICIAL AWS `nodejs24.x` managed runtime, so it can't use those. It therefore
// carries its own self-contained copy of the workload + timing harness, kept in
// lockstep with core.ts so the emitted record shape is identical and compare.ts
// treats it like any other variant.
//
// "aws-sdk bundled" / "aws-sdk disabled in the runtime": we import and BUNDLE
// @aws-sdk/client-s3 into the deployment zip (bun build --target=node) instead of
// relying on the SDK the managed runtime happens to preinstall. That makes the
// SDK cost part of THIS function's bundle + init, exactly like the layer/cmr
// aws-sdk variants — an apples-to-apples S3-client comparison across runtimes.

import { randomUUID } from "node:crypto";

import { GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";

interface BenchEvent {
  fileCount?: number;
  fileSizeBytes?: number;
  passes?: number;
}

interface PassTiming {
  pass: number;
  writeMs: number;
  readMs: number;
  totalMs: number;
  bytesRead: number;
}

interface BenchResult {
  runtime: string;
  s3client: string;
  bunVersion: string;
  arch: string;
  platform: string;
  region: string;
  bucket: string;
  prefix: string;
  fileCount: number;
  fileSizeBytes: number;
  passes: number;
  coldStart: boolean;
  initToFirstInvokeMs: number;
  perPass: PassTiming[];
  writeMsTotal: number;
  readMsTotal: number;
  handlerMs: number;
}

const region = process.env.AWS_REGION ?? "eu-west-1";
const bucket = process.env.BENCH_BUCKET ?? "";

// AWS SDK v3 S3 client. Auto-discovers the Lambda role from the environment.
// Constructed at module top so its init cost is paid during cold start, like the
// other aws-sdk variants.
const s3 = new S3Client({ region });

// Module-load timestamp. On a cold start this runs during init (after the SDK's
// module graph has loaded); on warm starts it keeps its init value.
const moduleLoadedAt = performance.now();
let invocationCount = 0;

export async function handler(event: BenchEvent, _context: unknown): Promise<BenchResult> {
  const handlerStart = performance.now();
  invocationCount += 1;
  const coldStart = invocationCount === 1;
  const initToFirstInvokeMs = coldStart ? handlerStart - moduleLoadedAt : 0;

  const fileCount = event.fileCount ?? Number(process.env.BENCH_FILE_COUNT ?? "100");
  const fileSizeBytes = event.fileSizeBytes ?? Number(process.env.BENCH_FILE_SIZE_BYTES ?? "1024");
  const passes = event.passes ?? Number(process.env.BENCH_PASSES ?? "1");

  if (bucket === "") {
    throw new Error("BENCH_BUCKET env var is not set");
  }

  const payload = new Uint8Array(fileSizeBytes).fill(65);
  const prefix = `bench/${randomUUID()}`;
  const perPass: PassTiming[] = [];
  let writeMsTotal = 0;
  let readMsTotal = 0;

  for (let pass = 0; pass < passes; pass += 1) {
    const keys = Array.from(
      { length: fileCount },
      (_unused, index) => `${prefix}/pass-${pass}/file-${index}.bin`,
    );

    const writeStart = performance.now();
    await Promise.all(keys.map((key) => writeObject(key, payload)));
    const writeMs = performance.now() - writeStart;

    const readStart = performance.now();
    const lengths = await Promise.all(keys.map((key) => readObject(key)));
    const readMs = performance.now() - readStart;

    const bytesRead = lengths.reduce((sum, length) => sum + length, 0);
    writeMsTotal += writeMs;
    readMsTotal += readMs;
    perPass.push({
      pass,
      writeMs: round(writeMs),
      readMs: round(readMs),
      totalMs: round(writeMs + readMs),
      bytesRead,
    });
  }

  const handlerMs = performance.now() - handlerStart;

  return {
    runtime: process.env.BENCH_RUNTIME_LABEL ?? "node",
    s3client: "aws-sdk",
    // Kept for schema parity with the Bun variants (core.ts emits Bun.version).
    // On the managed Node runtime we report the Node version instead.
    bunVersion: process.version,
    arch: process.arch,
    platform: process.platform,
    region,
    bucket,
    prefix,
    fileCount,
    fileSizeBytes,
    passes,
    coldStart,
    initToFirstInvokeMs: round(initToFirstInvokeMs),
    perPass,
    writeMsTotal: round(writeMsTotal),
    readMsTotal: round(readMsTotal),
    handlerMs: round(handlerMs),
  };
}

async function writeObject(key: string, body: Uint8Array): Promise<void> {
  await s3.send(new PutObjectCommand({ Bucket: bucket, Key: key, Body: body }));
}

async function readObject(key: string): Promise<number> {
  const response = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
  const bytes = await response.Body!.transformToByteArray();
  return bytes.byteLength;
}

function round(value: number): number {
  return Math.round(value * 1000) / 1000;
}
