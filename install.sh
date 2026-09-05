#!/usr/bin/env bash
# Install s3disk on this machine.
#
#   ./install.sh                 # build from source and install to /usr/local
#   PREFIX=$HOME/.local ./install.sh
#   ./install.sh --uninstall
#
# Installs:
#   $PREFIX/bin/s3disk            the binary
#   /sbin/mount.s3disk            mount(8) helper, so fstab entries work
#   /etc/systemd/system/s3disk@.service  (when systemd is present)
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNINSTALL=0
[ "${1:-}" = "--uninstall" ] && UNINSTALL=1

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

need_root() {
  case "$PREFIX" in
    "$HOME"/*) return 0 ;;
  esac
  [ "$(id -u)" -eq 0 ] || die "installing to $PREFIX needs root; re-run with sudo, or set PREFIX=\$HOME/.local"
}

if [ "$UNINSTALL" -eq 1 ]; then
  need_root
  say "removing s3disk"
  rm -f "$PREFIX/bin/s3disk" /sbin/mount.s3disk /etc/systemd/system/s3disk@.service
  say "done (configuration in /etc/s3disk and caches were left in place)"
  exit 0
fi

need_root

# ------------------------------------------------------------------- checks
[ -e /dev/fuse ] || warn "/dev/fuse is missing — load the fuse module, or run this inside a container started with --device /dev/fuse"
if ! command -v fusermount3 >/dev/null && ! command -v fusermount >/dev/null; then
  warn "fusermount is not installed; unmounting as a non-root user will not work"
  warn "  Debian/Ubuntu: apt-get install fuse3    RHEL/Fedora: dnf install fuse3    Alpine: apk add fuse3"
fi

# ------------------------------------------------------------------- build
if [ -x "$SRC_DIR/bin/s3disk" ] && [ "${REBUILD:-0}" != "1" ]; then
  say "using the existing build at bin/s3disk (set REBUILD=1 to rebuild)"
else
  command -v go >/dev/null || die "Go is required to build s3disk (or download a prebuilt binary). See https://go.dev/dl/"
  say "building s3disk"
  ( cd "$SRC_DIR" && CGO_ENABLED=0 go build -buildvcs=false -trimpath \
      -ldflags "-s -w -X main.version=$(git -C "$SRC_DIR" describe --tags --always --dirty 2>/dev/null || cat "$SRC_DIR/VERSION" 2>/dev/null || echo dev)" \
      -o bin/s3disk ./cmd/s3disk )
fi

# ----------------------------------------------------------------- install
say "installing to $PREFIX/bin/s3disk"
install -Dm755 "$SRC_DIR/bin/s3disk" "$PREFIX/bin/s3disk"

if [ -d /sbin ] && [ "$(id -u)" -eq 0 ]; then
  ln -sf "$PREFIX/bin/s3disk" /sbin/mount.s3disk
  say "registered the mount(8) helper (/sbin/mount.s3disk)"
fi

if [ -d /etc/systemd/system ] && [ "$(id -u)" -eq 0 ]; then
  install -Dm644 "$SRC_DIR/packaging/s3disk@.service" /etc/systemd/system/s3disk@.service
  mkdir -p /etc/s3disk
  [ -f /etc/s3disk/example.conf ] || install -Dm600 "$SRC_DIR/packaging/example.conf" /etc/s3disk/example.conf
  systemctl daemon-reload 2>/dev/null || true
  say "installed the systemd unit (s3disk@.service)"
fi

# -------------------------------------------------------------------- done
say "installed $("$PREFIX/bin/s3disk" version)"
cat <<TXT

Next steps:

  $PREFIX/bin/s3disk doctor s3://my-bucket        check FUSE and credentials
  $PREFIX/bin/s3disk mount s3://my-bucket /mnt/data
  $PREFIX/bin/s3disk status /mnt/data
  $PREFIX/bin/s3disk umount /mnt/data

To mount at boot, copy /etc/s3disk/example.conf to /etc/s3disk/<name>.conf and:

  systemctl enable --now s3disk@<name>

TXT
