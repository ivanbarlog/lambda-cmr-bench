// Shared benchmark workload + timing harness. The S3 client is injected so the
// two entry handlers (bun-native vs aws-sdk) each bundle ONLY their own client —
// keeping cold-start init cost representative of that client alone.

export interface S3Adapter {
  readonly name: string;
  write(key: string, body: Uint8Array): Promise<void>;
  read(key: string): Promise<number>; // returns byte length read
}

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

// Module-load timestamp. On a cold start this runs during init (after the chosen
// S3 client's module graph has loaded); on warm starts it keeps its init value.
const moduleLoadedAt = performance.now();
let invocationCount = 0;

const region = process.env.AWS_REGION ?? "eu-west-1";
const bucket = process.env.BENCH_BUCKET ?? "";

export function makeHandler(adapter: S3Adapter) {
  return async function handler(event: BenchEvent, _context: unknown): Promise<BenchResult> {
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
    const prefix = `bench/${Bun.randomUUIDv7()}`;
    const perPass: PassTiming[] = [];
    let writeMsTotal = 0;
    let readMsTotal = 0;

    for (let pass = 0; pass < passes; pass += 1) {
      const keys = Array.from(
        { length: fileCount },
        (_unused, index) => `${prefix}/pass-${pass}/file-${index}.bin`,
      );

      const writeStart = performance.now();
      await Promise.all(keys.map((key) => adapter.write(key, payload)));
      const writeMs = performance.now() - writeStart;

      const readStart = performance.now();
      const lengths = await Promise.all(keys.map((key) => adapter.read(key)));
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
      runtime: process.env.BENCH_RUNTIME_LABEL ?? "unknown",
      s3client: adapter.name,
      bunVersion: Bun.version,
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
  };
}

export const sharedRegion = region;
export const sharedBucket = bucket;

function round(value: number): number {
  return Math.round(value * 1000) / 1000;
}
