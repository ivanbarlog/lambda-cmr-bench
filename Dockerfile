# syntax=docker/dockerfile:1
#
# Customer-Managed Runtime (CMR) image for a Bun custom runtime.
# Built and pushed by setup.sh.
#
# CMR image notes (tested on GA with this image):
#   - The entry point is /var/runtime/bootstrap.
#   - Do NOT set ENTRYPOINT in the image. An image ENTRYPOINT leaves _HANDLER empty, so
#     the runtime fails with "Invalid handler format". Tested: the same image with an
#     ENTRYPOINT (with or without CMD []) fails, without it works. CMD alone was not tested.
#   - The base is provided:al2023, which has /var/task. Nothing is placed in /var/task or
#     /opt here. Whether other bases work, and whether those paths are required or reserved,
#     was not tested.
#   - The ECR image is pushed as Docker v2 Schema 2 (oci-mediatypes=false, see setup.sh) as
#     the beta guide asked. Whether OCI works on GA was not tested.

# IMPORTANT: use the glibc (Debian) image, NOT -alpine. The Lambda base
# public.ecr.aws/lambda/provided:al2023 is glibc; an Alpine/musl bun binary
# cannot exec there and the runtime fails at cold start with "exit status 127".
FROM oven/bun:1.4.4 AS bun

WORKDIR /opt
COPY runtime/runtime.mts .

# Bundle the runtime interface client into a single file that Bun executes at start.
RUN bun build runtime.mts --target=bun --production --outfile runtime.mjs

FROM public.ecr.aws/lambda/provided:al2023

# Bun binary + bundled runtime + bootstrap live under /var/runtime.
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
COPY --from=bun /opt/runtime.mjs /var/runtime/runtime.mjs
COPY runtime/bootstrap /var/runtime/bootstrap

RUN chmod 0755 /var/runtime/bootstrap

# For local testing run the bootstrap explicitly, e.g.
#   docker run --entrypoint /var/runtime/bootstrap <image>

# Marker file used to prove which runtime version served an invoke.
RUN echo "CMR Bun Runtime - Version 1" > /var/runtime/runtime-info.txt
