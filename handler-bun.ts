import { S3Client } from "bun";

import { makeHandler, sharedBucket, sharedRegion } from "./core";
import type { S3Adapter } from "./core";

// Credential resolution for Bun's native S3 client.
//
// Bun's S3Client only understands STATIC credentials (accessKeyId /
// secretAccessKey / sessionToken); it has no AWS credential-provider chain.
//
//   - Normal Lambda: the execution role's temporary credentials are exposed as
//     the AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN env vars,
//     so we read those directly.
//   - SnapStart: those static env vars are NOT populated after a restore (they'd
//     be stale in the snapshot). Instead Lambda serves fresh credentials from the
//     container credentials endpoint (AWS_CONTAINER_CREDENTIALS_FULL_URI, with the
//     AWS_CONTAINER_AUTHORIZATION_TOKEN as the Authorization header). The AWS SDK
//     resolves this automatically; for Bun we fetch it ourselves.
//
// Resolved lazily on first use (after restore for SnapStart) and memoized.
interface Creds {
  accessKeyId: string;
  secretAccessKey: string;
  sessionToken?: string;
}

async function resolveCreds(): Promise<Creds> {
  const staticKey = process.env.AWS_ACCESS_KEY_ID;
  const staticSecret = process.env.AWS_SECRET_ACCESS_KEY;
  if (staticKey != null && staticKey !== "" && staticSecret != null && staticSecret !== "") {
    return {
      accessKeyId: staticKey,
      secretAccessKey: staticSecret,
      sessionToken: process.env.AWS_SESSION_TOKEN,
    };
  }

  const fullUri = process.env.AWS_CONTAINER_CREDENTIALS_FULL_URI;
  if (fullUri == null || fullUri === "") {
    throw new Error(
      "No AWS credentials: neither AWS_ACCESS_KEY_ID nor AWS_CONTAINER_CREDENTIALS_FULL_URI is set",
    );
  }
  const token = process.env.AWS_CONTAINER_AUTHORIZATION_TOKEN;
  const response = await fetch(fullUri, {
    headers: token == null ? {} : { Authorization: token },
  });
  if (!response.ok) {
    throw new Error(`Container credentials endpoint returned ${response.status}`);
  }
  const body = (await response.json()) as {
    AccessKeyId: string;
    SecretAccessKey: string;
    Token?: string;
  };
  return {
    accessKeyId: body.AccessKeyId,
    secretAccessKey: body.SecretAccessKey,
    sessionToken: body.Token,
  };
}

let clientPromise: Promise<S3Client> | undefined;
function s3(): Promise<S3Client> {
  if (clientPromise == null) {
    clientPromise = resolveCreds().then(
      (creds) =>
        new S3Client({
          region: sharedRegion,
          bucket: sharedBucket,
          accessKeyId: creds.accessKeyId,
          secretAccessKey: creds.secretAccessKey,
          sessionToken: creds.sessionToken,
        }),
    );
  }
  return clientPromise;
}

const adapter: S3Adapter = {
  name: "bun",
  async write(key, body) {
    const client = await s3();
    await client.write(key, body);
  },
  async read(key) {
    const client = await s3();
    const buffer = await client.file(key).arrayBuffer();
    return buffer.byteLength;
  },
};

export const handler = makeHandler(adapter);
