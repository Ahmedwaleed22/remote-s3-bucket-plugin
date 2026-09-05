# s3disk — mount an S3 bucket as a normal filesystem.
#
# Build:
#   docker build -f docker/Dockerfile -t s3disk:latest .
#
# Run (mount for other tools in the same container):
#   docker run --rm -it \
#     --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
#     -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
#     -e S3DISK_BUCKET=s3://my-bucket/project \
#     s3disk:latest -- ls -la /workspace

# ---------------------------------------------------------------- build stage
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS build

WORKDIR /src

# Dependencies first, so edits to the source do not re-download the module cache.
COPY go.mod go.sum ./
RUN go mod download

COPY cmd ./cmd
COPY internal ./internal

ARG VERSION=dev
ARG TARGETARCH
# A fully static binary: the runtime image needs no libc and no Go toolchain.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH:-amd64} \
    go build -buildvcs=false -trimpath \
      -ldflags "-s -w -X main.version=${VERSION}" \
      -o /out/s3disk ./cmd/s3disk

# -------------------------------------------------------------- runtime stage
FROM alpine:3.20

# fuse3 supplies fusermount3, used to unmount and to mount without CAP_SYS_ADMIN.
# ca-certificates is required to talk to S3 over TLS.
RUN apk add --no-cache fuse3 ca-certificates tini \
 && echo "user_allow_other" >> /etc/fuse.conf

COPY --from=build /out/s3disk /usr/local/bin/s3disk
COPY docker/entrypoint.sh /usr/local/bin/s3disk-entrypoint
# Lets the kernel's mount(8) find us: `mount -t fuse.s3disk bucket /mnt`.
RUN ln -s /usr/local/bin/s3disk /sbin/mount.s3disk \
 && chmod +x /usr/local/bin/s3disk-entrypoint

# Where the bucket appears, and where cached blocks are kept. Declaring the
# cache a volume keeps it off the container's writable layer.
#
# S3DISK_EXCLUSIVE assumes the usual container setup: this container owns its
# bucket or prefix and nothing else writes to it. Cached metadata then never
# needs re-checking. Pass -e S3DISK_EXCLUSIVE=false if that is not true.
ENV S3DISK_MOUNTPOINT=/workspace \
    S3DISK_CACHE_DIR=/var/cache/s3disk \
    S3DISK_EXCLUSIVE=true \
    S3DISK_MOUNT_ARGS=""
VOLUME ["/var/cache/s3disk"]
WORKDIR /workspace

# Reports unhealthy if the mount has gone away or the daemon stopped answering.
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD s3disk status "$S3DISK_MOUNTPOINT" >/dev/null 2>&1 || exit 1

# tini reaps zombies and forwards signals, so a SIGTERM reaches s3disk and the
# filesystem is flushed and unmounted cleanly.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/s3disk-entrypoint"]
