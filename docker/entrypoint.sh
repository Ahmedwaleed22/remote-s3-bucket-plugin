#!/bin/sh
# s3disk container entrypoint.
#
# Three ways to run this image:
#
#   1. No arguments — mount the bucket and stay in the foreground. Use this as a
#      sidecar, or with a shared mount propagated to the host.
#
#   2. `-- COMMAND [ARGS…]` — mount the bucket, run COMMAND with the project
#      available as a normal directory, then flush and unmount when it exits.
#      This is the mode agents want: the command sees a plain filesystem.
#
#   3. An s3disk subcommand (doctor, status, sync, version, …) — run it directly.
#
# Configuration comes from the environment:
#   S3DISK_BUCKET      s3://bucket/prefix to mount            (required for 1 and 2)
#   S3DISK_MOUNTPOINT  where to mount it                      (default /workspace)
#   S3DISK_CACHE_DIR   local block cache                      (default /var/cache/s3disk)
#   S3DISK_ENDPOINT    S3 endpoint URL for non-AWS providers
#   S3DISK_PATH_STYLE  "true" for MinIO/Ceph-style addressing
#   S3DISK_EXCLUSIVE   "true" (the image default) when this container is the only
#                      writer for its bucket/prefix, which is the normal setup:
#                      one bucket or folder per container. Set it to "false" if
#                      anything else writes to the same prefix concurrently.
#   S3DISK_MOUNT_ARGS  any extra s3disk mount flags
#   AWS_*              standard AWS credential and region variables
set -eu

MOUNTPOINT="${S3DISK_MOUNTPOINT:-/workspace}"
CACHE_DIR="${S3DISK_CACHE_DIR:-/var/cache/s3disk}"

die() { echo "s3disk-entrypoint: $*" >&2; exit 1; }

# Pass s3disk's own subcommands straight through.
case "${1:-}" in
  mount|umount|unmount|status|sync|list|ls|doctor|version|--version|-v|help|--help|-h)
    exec s3disk "$@"
    ;;
esac

[ -e /dev/fuse ] || die "/dev/fuse is missing — run with: --device /dev/fuse --cap-add SYS_ADMIN"
[ -n "${S3DISK_BUCKET:-}" ] || die "set S3DISK_BUCKET to the bucket to mount, e.g. s3://my-bucket/project"

[ "${1:-}" = "--" ] && shift

mkdir -p "$MOUNTPOINT" "$CACHE_DIR"

# shellcheck disable=SC2086  # S3DISK_MOUNT_ARGS is intentionally word-split
set_mount_args() {
  MOUNT_ARGS="--cache-dir $CACHE_DIR"
  [ -n "${S3DISK_ENDPOINT:-}" ] && MOUNT_ARGS="$MOUNT_ARGS --endpoint $S3DISK_ENDPOINT"
  case "${S3DISK_PATH_STYLE:-}" in
    1|true|yes|on) MOUNT_ARGS="$MOUNT_ARGS --path-style" ;;
  esac
  case "${S3DISK_EXCLUSIVE:-true}" in
    1|true|yes|on) MOUNT_ARGS="$MOUNT_ARGS --exclusive" ;;
  esac
  MOUNT_ARGS="$MOUNT_ARGS ${S3DISK_MOUNT_ARGS:-}"
}
set_mount_args

if [ "$#" -eq 0 ]; then
  # Mode 1: stay in the foreground and serve the mount. s3disk installs its own
  # SIGTERM handler, which flushes pending writes before unmounting.
  echo "s3disk: mounting $S3DISK_BUCKET at $MOUNTPOINT"
  # shellcheck disable=SC2086
  exec s3disk mount "$S3DISK_BUCKET" "$MOUNTPOINT" --foreground $MOUNT_ARGS
fi

# Mode 2: mount, run the command, unmount.
echo "s3disk: mounting $S3DISK_BUCKET at $MOUNTPOINT"
# shellcheck disable=SC2086
s3disk mount "$S3DISK_BUCKET" "$MOUNTPOINT" $MOUNT_ARGS || die "mount failed"

unmount() {
  echo "s3disk: flushing and unmounting $MOUNTPOINT"
  s3disk umount "$MOUNTPOINT" >/dev/null 2>&1 || true
}
forward() { kill -TERM "$child" 2>/dev/null || true; }
trap forward TERM INT
trap unmount EXIT

"$@" &
child=$!

# `wait` returns as soon as a trapped signal arrives, even though the child is
# still shutting down. Keep waiting until the child is really gone, so the
# command's own exit status is the one the container reports.
rc=0
while :; do
  wait "$child"
  rc=$?
  kill -0 "$child" 2>/dev/null || break
done
exit "$rc"
