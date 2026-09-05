# A workspace image for coding agents: the project lives in S3 and appears at
# /workspace as an ordinary directory, with the usual toolchains available.
#
#   docker build -f examples/agent.Dockerfile -t s3disk-agent .
#   docker run --rm -it \
#     --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
#     -e S3DISK_BUCKET=s3://my-bucket/project \
#     -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
#     s3disk-agent
#
# Everything the agent writes to /workspace is uploaded to S3 as it closes each
# file; nothing else has to change.

FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
ARG VERSION=dev
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH:-amd64} go build -buildvcs=false -trimpath \
      -ldflags "-s -w -X main.version=${VERSION}" -o /out/s3disk ./cmd/s3disk

FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      fuse3 ca-certificates curl git openssh-client jq ripgrep \
      build-essential python3 python3-pip python3-venv \
      tini \
 && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && echo "user_allow_other" >> /etc/fuse.conf

COPY --from=build /out/s3disk /usr/local/bin/s3disk
COPY docker/entrypoint.sh /usr/local/bin/s3disk-entrypoint
RUN chmod +x /usr/local/bin/s3disk-entrypoint && ln -s /usr/local/bin/s3disk /sbin/mount.s3disk

ENV S3DISK_MOUNTPOINT=/workspace \
    S3DISK_CACHE_DIR=/var/cache/s3disk \
    S3DISK_EXCLUSIVE=true
VOLUME ["/var/cache/s3disk"]
WORKDIR /workspace

# With no command, drops into a shell with the bucket mounted at /workspace.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/s3disk-entrypoint"]
CMD ["bash"]
