# lambda-cmr-bench

Companion material for the blog post [Running Bun on Lambda Customer Managed Runtimes](https://barlog.sk/blog/lambda-customer-managed-runtimes-bun).

The post covers AWS Lambda customer-managed runtimes (CMR), what I learned
testing them during the beta, and the benchmark results. This repository holds
the code behind those numbers so you can reproduce them in your own account.
It is a snapshot taken for the post, not a maintained project. It deploys real
AWS resources (S3, IAM, ECR, Lambda) that cost money, so read the scripts and
run `./destroy.sh` when you are done.

# Bun runtime benchmark: CMR image vs. Lambda layer vs. container image x Bun-S3 vs. AWS-SDK-S3

A matrix comparing how the Bun runtime is *delivered* and which S3 client the
handler uses, **plus a Node.js baseline**. Same workload, same function config -
only the delivery/client axes vary:

|                | S3 client: **bun** (native) | S3 client: **aws-sdk** (`@aws-sdk/client-s3`) |
| -------------- | --------------------------- | --------------------------------------------- |
| **cmr** (image)  | `bun-bench-cmr-bun`      | `bun-bench-cmr-awssdk`                        |
| **layer** (`provided.al2023`) | `bun-bench-layer-bun` | `bun-bench-layer-awssdk`             |
| **docker** (container image) | `bun-bench-docker-bun` | `bun-bench-docker-awssdk`             |
| **docker + SnapStart** (container image) | `bun-bench-docker-bun-snap` | `bun-bench-docker-awssdk-snap` |

Plus one **Node.js baseline** outside the Bun matrix:

| Runtime                          | S3 client                         | Function                |
| -------------------------------- | --------------------------------- | ----------------------- |
| **node** (`nodejs24.x`, managed) | **aws-sdk** (`@aws-sdk/client-s3`, bundled) | `bun-bench-node-awssdk` |

Delivery mechanisms:

| Delivery  | How the runtime ships                                | Deployed via                                    | Entry                    |
| --------- | ---------------------------------------------------- | ----------------------------------------------- | ------------------------ |
| **cmr**   | Bun baked into a container image (Customer-Managed Runtime) | `aws lambda` (`--runtime-config`) + `aws lambda-core` (runtime resources) | `/var/runtime/bootstrap` |
| **layer** | Bun as a Lambda layer (`@beesolve/lambda-bun-runtime`) | `aws lambda` (standard - emulates the CDK `BunFunction`) | `/opt/bootstrap` |
| **docker** | Bun + handler baked into a container **function** image | `aws lambda` (standard, `--package-type Image`) | `/var/runtime/bootstrap` |
| **node**  | Official AWS `nodejs24.x` managed runtime            | `aws lambda` (standard)                          | managed                  |

The Bun runtime code is identical across all the Bun functions (the layer's
`runtime.js` is the minified build of the same runtime source as
`runtime/runtime.mts` here; the docker image bundles that same source). So the
matrix isolates:

- **Delivery overhead** (cmr vs layer vs docker) - cold-start init, holding S3 client constant.
- **S3 client cost** (bun native vs AWS SDK) - bundle size, cold-start init impact
  of loading the SDK, and warm S3 throughput, holding delivery constant.
- **SnapStart effect** (docker vs docker + SnapStart) - how much a pre-initialized
  snapshot cuts cold-start init for the container-image Bun function.
- **Runtime baseline** (node vs Bun) - the `node/aws-sdk` function is the official
  managed-runtime reference point for the same AWS-SDK S3 client, so you can see
  what Bun (via cmr/layer/docker) costs relative to plain `nodejs24.x`.

All Bun functions are `arm64`, 1024 MB, 60s timeout, same IAM role, same S3
bucket, same workload; the Node baseline matches all of these. All use
`PER_TENANT` tenancy **except** the two `docker + SnapStart` functions (SnapStart
is incompatible with tenancy - see below).

## The container-image variants (`docker` / `docker + SnapStart`)

`docker` deploys the **same Bun handler as a real container-image function**
(`--package-type Image`) via the standard `aws lambda` service. Unlike the CMR
image (which ships only the *runtime* under `/var/runtime` and deploys the handler
zip separately), the docker image is the whole function: Bun + the runtime
interface client + the handler bundle in `/var/task`. `Dockerfile.function` builds
one image per S3 client (`--build-arg HANDLER_VARIANT=bun|awssdk`).

Because it runs on the standard Lambda service, the docker variant can opt into
**[SnapStart for container images](https://aws.amazon.com/about-aws/whats-new/2026/07/aws-lambda-snapstart-container/)**
(GA). The `docker + SnapStart` functions are created with
`--snap-start ApplyOn=PublishedVersions`; deploy-docker.sh then publishes a
version (which is when Lambda snapshots the initialized environment) and points a
`snap` alias at it. SnapStart applies only to **published versions**, so the
with/without comparison uses **separate functions** - the non-snap ones are
invoked on `$LATEST`, the snap ones via the `snap` alias. A custom base image
needs no runtime restore hooks here: the Bun runtime simply blocks on the
runtime-API `next` call while the snapshot is taken.

**SnapStart is incompatible with tenancy configuration**, so the two
`docker + SnapStart` functions are the only ones that *don't* use `PER_TENANT`.
That means the usual "fresh `--tenant-id` = cold start" trick can't force their
cold starts. Instead, `run-benchmark.sh` forces them with a **concurrent invoke
burst** (Lambda scales out to fresh execution environments, each a snapshot
restore = cold) and classifies each invoke as cold or warm from the CloudWatch
`REPORT` line: a SnapStart cold reports **`Restore Duration`** (and omits
`Init Duration`), a warm reports neither. This log-derived classification is
self-correcting - a burst invoke that happens to reuse a warm environment is
simply recorded as warm.

Two SnapStart specifics the Bun runtime/handler had to handle (both are the
reason SnapStart "just works" for managed runtimes but needs care on a custom
one):

- **Restore handshake.** A custom runtime must call `GET /runtime/restore/next`
  after init and before its first `/invocation/next`; that call blocks while the
  snapshot is taken and returns on restore. `runtime/runtime.mts` does this, and
  treats a `404` (SnapStart not enabled - the cmr/layer/non-snap functions) as
  "skip and go straight to the invocation loop." Without it, the publish-time
  init phase hangs until it times out (130s) and the version fails to snapshot.
- **Credentials.** Under SnapStart the static `AWS_ACCESS_KEY_ID` /
  `AWS_SECRET_ACCESS_KEY` env vars are **not** repopulated after a restore;
  Lambda serves fresh credentials from the container credentials endpoint
  (`AWS_CONTAINER_CREDENTIALS_FULL_URI` + `AWS_CONTAINER_AUTHORIZATION_TOKEN`).
  The AWS SDK resolves this automatically, but Bun's native `S3Client` only takes
  static keys, so `handler-bun.ts` resolves credentials lazily on first use -
  static env vars when present (normal Lambda), otherwise the container endpoint
  (SnapStart).

## The Node.js baseline (`node/aws-sdk`)

`handler-node.ts` runs on the official `nodejs24.x` managed runtime and **bundles
`@aws-sdk/client-s3` into the deployment zip** (`bun build --target=node`) rather
than resolving the SDK the runtime happens to preinstall. Bundling it means the
SDK's size and init cost are attributed to *this* function - exactly like the
`cmr/aws-sdk` and `layer/aws-sdk` Bun variants - so the S3-client comparison is
apples-to-apples across runtimes.

Because the managed Node runtime can't run the Bun-only `core.ts` (it uses
`Bun.randomUUIDv7`, `Bun.version`, `Bun.file`), `handler-node.ts` carries its own
self-contained copy of the workload + timing harness (`node:crypto` `randomUUID`,
`process.version`, `performance.now`), kept in lockstep with `core.ts` so the
emitted record shape is identical and `compare.ts` treats it like any other
variant.

The Node baseline is **optional**: `run-benchmark.sh` skips it if the function
isn't deployed, so you can run the Bun-only matrix without it.

## Why separate functions per S3 client

Each S3-client variant is a **separate function with its own handler zip**, so its
cold-start init cost reflects *only* the client it bundles. The AWS SDK is imported
at module top (like a real handler), so its ~480 KB bundle loads during init - that
cost is exactly what we want to attribute to the SDK. A runtime `if` inside one
function would load both clients and make the init comparison meaningless.

Bundle sizes are recorded to `results/bundle-sizes.json` at build time and printed
by `compare.ts` (typical: bun ≈ **1.5 KB**, aws-sdk ≈ **480 KB** minified).

## Workload

`core.ts` writes N files of S bytes to S3 then reads them all back, `passes` times,
under a per-invoke `bench/<uuidv7>/` prefix (runs never collide). All timings use
`performance.now()`. The S3 client is injected by the entry handler
(`handler-bun.ts` or `handler-awssdk.ts`). Configurable via event payload or env:

```json
{ "fileCount": 100, "fileSizeBytes": 1024, "passes": 1 }
```

Defaults: 100 files × 1 KB × 1 pass.

## What is measured

Per invoke, three layers of timing:

- **CloudWatch `REPORT`** (authoritative): `Init Duration` (normal cold-start
  init) or `Restore Duration` (SnapStart cold-start restore), `Duration`,
  `Billed Duration`, `Max Memory Used` - parsed from `--log-type Tail`. The total
  cold-start cost `compare.ts` reports as `coldStartMs` is `(Restore | Init) +
  Duration`, uniform across normal and SnapStart functions.
- **Client wall-clock**: time around the `aws ... invoke` call (`EPOCHREALTIME`).
- **Handler self-report**: `initToFirstInvokeMs` (module-load → first invoke, cold
  only), `handlerMs`, `writeMsTotal`, `readMsTotal` from the response payload.

Plus **bundle size** per S3 client (from `results/bundle-sizes.json`).

> Note: CMR functions report `Init Duration` in the `REPORT` line. If it is ever
> missing, `compare.ts` shows `-` and you can fall back to
> `handler.initToFirstInvokeMs` + client wall-clock for cold cost.

## Cold vs. warm

All functions are `PER_TENANT` **except** the two `docker + SnapStart` functions,
so for everything else a **fresh `--tenant-id` (UUIDv7) forces a cold start**.
Each round: 1 cold invoke on a new tenant, then `WARM_ROUNDS` warm invokes
reusing that tenant.

The `docker + SnapStart` variants can't use tenancy, so `run-benchmark.sh` forces
their cold (snapshot-restore) starts with a **concurrent invoke burst** (default
`COLD_BURST=WARM_ROUNDS` parallel invokes per round → Lambda scales out to fresh
restored environments), then does serial warm invokes. Cold vs warm is decided
from the `REPORT` line - **`Restore Duration` present = cold** (SnapStart), `Init
Duration` present = cold (normal), neither = warm - not from the invoke position,
so the count is self-correcting. Tune the burst with `COLD_BURST`.

## Raw results

`data/` holds the raw per-invoke records (one JSON object per invoke, JSONL) and the
`compare.ts` output of the three runs used in the post. All runs: 10 cold rounds x 10 warm
invokes per function, `eu-west-1`, arm64, 1024 MB, 100 files x 1 KB x 1 pass.

| Directory | Run |
| --- | --- |
| `data/beta-2026-09-03/` | Private beta, Bun 1.4.0 |
| `data/ga-bun-1.4.0/` | GA, Bun 1.4.0 |
| `data/ga-bun-1.4.4/` | GA, Bun 1.4.4 |

Print the summary tables of a run yourself:

```bash
bun compare.ts data/ga-bun-1.4.4/*.jsonl
```

The only edit to the raw files: the AWS account ID in the bucket name was replaced with
`123456789012`. Your own runs go to `results/`, which stays gitignored.

## Prerequisites

- **A recent AWS CLI v2** that includes the `lambda-core` service (customer-managed
  runtimes) and `aws lambda create-function --runtime-config`. No extra models or
  allow-listing are needed.
- **Docker** running (for the CMR runtime image build in `setup.sh`).
- **Bun** and `bun install` in this folder - pulls `@aws-sdk/client-s3` (bundled into
  the aws-sdk handler) and `@beesolve/lambda-bun-runtime` (its
  `dist/bun-lambda-layer-*.zip` is the layer published by `deploy-layer.sh`; its
  code is never bundled into a handler).
- AWS credentials. The region defaults to `eu-west-1` (override with `AWS_REGION`).
  The account ID is read from the active credentials (`aws sts get-caller-identity`);
  set `ACCOUNT_ID` to override it and `AWS_PROFILE` to pick a profile (see `config.sh`).

## Run it

```bash
bun install                 # once

# 1. Infra + CMR runtime: S3 bucket, IAM role, ECR repo, build/push image,
#    create runtime + version + alias
./setup.sh

# 2. Deploy the functions (each script deploys its S3-client variants)
./deploy-cmr.sh             # attaches CMR functions to the runtime from step 1
./deploy-layer.sh
./deploy-docker.sh          # optional: container-image variants (+ SnapStart)
./deploy-node.sh            # optional: nodejs24.x baseline (aws-sdk bundled)

# 3. Run the benchmark (defaults: 10 cold rounds × 10 warm each, per function)
./run-benchmark.sh          # includes docker/docker-snap/node variants if deployed

# 4. Compare (the run prints the glob to use)
bun compare.ts results/*-<ts>.jsonl

# 5. Tear everything down when done
./destroy.sh --yes          # add --iam to also remove the IAM role
```

## Tuning (env vars, all optional)

```bash
# Workload defaults baked into function env (redeploy to change defaults)
BENCH_FILE_COUNT=100 BENCH_FILE_SIZE_BYTES=1024 BENCH_PASSES=1

# Sampling (no redeploy)
COLD_ROUNDS=20 WARM_ROUNDS=15 ./run-benchmark.sh
```

Workload params in the invoke payload override the function env defaults, so you
can sweep sizes without redeploying - `run-benchmark.sh` builds the payload from
`BENCH_*`, so just export and re-run:

```bash
BENCH_FILE_SIZE_BYTES=65536 ./run-benchmark.sh
```

## Files

| File                 | Purpose                                                          |
| -------------------- | ---------------------------------------------------------------- |
| `core.ts`            | Shared workload + timing harness; S3 client injected             |
| `handler-bun.ts`     | Entry - Bun native `S3Client` adapter                            |
| `handler-awssdk.ts`  | Entry - AWS SDK v3 `@aws-sdk/client-s3` adapter                  |
| `handler-node.ts`    | Entry - nodejs24.x baseline; self-contained harness + bundled AWS SDK v3 |
| `runtime/runtime.mts`| The Bun runtime interface client baked into the CMR + docker images |
| `runtime/bootstrap`  | CMR / docker entry script - launches bun on `runtime.mjs`       |
| `Dockerfile`         | Builds the CMR runtime image (glibc bun on `provided.al2023`)    |
| `Dockerfile.function`| Builds the container-image **function** (Bun + RIC + handler in `/var/task`) |
| `config.sh`          | Shared config + `build_handler_zip` (records bundle sizes)       |
| `setup.sh`           | S3 bucket + IAM role + ECR repo + build/push image + create runtime/version/alias |
| `deploy-cmr.sh`      | Deploy both CMR function variants (attach to the runtime from setup.sh) |
| `deploy-layer.sh`    | Publish layer, deploy both `provided.al2023` variants (std lambda) |
| `deploy-docker.sh`   | Build/push function images, deploy container-image variants ± SnapStart (std lambda) |
| `deploy-node.sh`     | Deploy the `nodejs24.x` baseline function (std lambda, aws-sdk bundled) |
| `run-benchmark.sh`   | Drive cold+warm invokes for all functions, collect timings → `results/` |
| `compare.ts`         | Aggregate JSONL; bundle-size table, per-variant p50/p95, verdicts |
| `destroy.sh`         | Tear down everything setup + deploy created (dry-run by default)  |
| `package.json`       | Dev deps: `@aws-sdk/client-s3` (bundled) + `@beesolve/lambda-bun-runtime` (layer zip source) |

## Teardown

`destroy.sh` removes exactly what `setup.sh` + the deploy scripts created
(functions → their CloudWatch log groups → runtime alias/versions/runtime → layer →
ECR repos (CMR runtime image + docker function images) → S3 bucket), in dependency
order, using the names from `config.sh`. Docker function versions/aliases are
removed automatically with the function. Dry-run by default.

```bash
./destroy.sh              # preview what would be deleted
./destroy.sh --yes        # delete functions/runtime/layer/ECR/bucket
./destroy.sh --yes --iam  # also delete the IAM role
```

> `destroy.sh` is the one-step cleanup for the CMR runtime, its versions and aliases.

## Caveats

- **Do not set `ENTRYPOINT` in the CMR runtime image.** On GA, an image `ENTRYPOINT`
  leaves `_HANDLER` empty and the runtime fails with `Invalid handler format: ""`. Tested:
  the same image with an `ENTRYPOINT` (with or without `CMD []`) fails, without it works.
  `CMD` on its own was not tested.
- Deleting a runtime is soft: it stays `PENDING_DELETION` for 30 days and its name
  stays reserved. Re-running `setup.sh` right after `destroy.sh --yes` needs a new
  `RUNTIME_NAME`.
- Lambda cold-start timing has variance; use ≥10–20 cold rounds, read p50/p95.
- In my runs the first cold round after a deploy was sometimes an outlier - discard it
  if it is.
- All functions share one S3 bucket + region, so network/S3 variance affects all
  equally.
- The AWS SDK cold-start cost depends on how much of it the bundler tree-shakes.
  We import only `S3Client` + `GetObjectCommand`/`PutObjectCommand`; a handler that
  imports more of the SDK would pay more.
