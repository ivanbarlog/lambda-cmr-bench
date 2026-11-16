import { GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";

import { makeHandler, sharedBucket, sharedRegion } from "./core";
import type { S3Adapter } from "./core";

// AWS SDK v3 S3 client. Auto-discovers the Lambda role from the environment.
const s3 = new S3Client({ region: sharedRegion });

const adapter: S3Adapter = {
  name: "aws-sdk",
  async write(key, body) {
    await s3.send(new PutObjectCommand({ Bucket: sharedBucket, Key: key, Body: body }));
  },
  async read(key) {
    const response = await s3.send(new GetObjectCommand({ Bucket: sharedBucket, Key: key }));
    const bytes = await response.Body!.transformToByteArray();
    return bytes.byteLength;
  },
};

export const handler = makeHandler(adapter);
