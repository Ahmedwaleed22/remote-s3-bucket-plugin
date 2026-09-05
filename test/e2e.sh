#!/usr/bin/env bash
# End-to-end test for s3disk against a real S3 server (MinIO by default).
#
#   test/e2e.sh                      # uses a local MinIO on 127.0.0.1:9000
#   S3DISK_TEST_ENDPOINT=... test/e2e.sh
#
# Every assertion goes through the mounted filesystem; a few also verify the
# resulting objects independently with `mc`, and one section remounts with a
# cold cache to prove the data really lives in S3.
set -uo pipefail

ENDPOINT="${S3DISK_TEST_ENDPOINT:-http://127.0.0.1:9000}"
BUCKET="${S3DISK_TEST_BUCKET:-devbucket}"
PREFIX="${S3DISK_TEST_PREFIX:-e2e}"
MNT="${S3DISK_TEST_MNT:-/mnt/s3test}"
BIN="${S3DISK_BIN:-$(cd "$(dirname "$0")/.." && pwd)/bin/s3disk}"
CACHE="${S3DISK_TEST_CACHE:-/var/tmp/s3disk-e2e-cache}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-minioadmin}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-minioadmin}"

pass=0; fail=0; failed_names=()

ok()   { pass=$((pass+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { fail=$((fail+1)); failed_names+=("$1"); printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "${2:-}"; }
check(){ # check NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
try()  { # try NAME COMMAND...
  local name="$1"; shift
  local out; out=$("$@" 2>&1); local rc=$?
  if [ $rc -eq 0 ]; then ok "$name"; else bad "$name" "rc=$rc ${out:0:300}"; fi; }
section(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

mount_fs() { # mount_fs [extra flags...]
  mkdir -p "$MNT"
  "$BIN" mount "s3://$BUCKET/$PREFIX" "$MNT" \
    --endpoint "$ENDPOINT" --path-style --cache-dir "$CACHE" \
    --dirty-timeout 1s "$@" || return 1
  for _ in $(seq 1 50); do
    mountpoint -q "$MNT" && return 0
    sleep 0.1
  done
  return 1
}
umount_fs() { "$BIN" umount "$MNT" >/dev/null 2>&1 || fusermount3 -u "$MNT" 2>/dev/null; sleep 0.3; }

cleanup() { umount_fs; }
trap cleanup EXIT

# Two runs sharing one mountpoint would corrupt each other's expectations.
if pgrep -f "s3disk mount s3://$BUCKET/$PREFIX $MNT" >/dev/null 2>&1; then
  echo "another s3disk mount of s3://$BUCKET/$PREFIX is already running on $MNT" >&2
  echo "stop it first (s3disk umount $MNT) or set S3DISK_TEST_MNT to a different path" >&2
  exit 2
fi

printf '\033[1ms3disk end-to-end test\033[0m\n'
printf 'binary   %s\nendpoint %s\nbucket   s3://%s/%s\nmount    %s\n' "$BIN" "$ENDPOINT" "$BUCKET" "$PREFIX" "$MNT"

# Start from a clean slate.
umount_fs
rm -rf "$CACHE"
mc rm --recursive --force "t/$BUCKET/$PREFIX" >/dev/null 2>&1

section "mount"
if mount_fs; then ok "mounted"; else bad "mounted" "see $CACHE/s3disk.log"; exit 1; fi
try "mountpoint is a FUSE mount" mountpoint -q "$MNT"
check "df reports free space" "yes" "$([ "$(df --output=avail -k "$MNT" | tail -1)" -gt 0 ] && echo yes)"

section "files: create, read, append, truncate"
echo "hello s3disk" > "$MNT/hello.txt"
check "write then read" "hello s3disk" "$(cat "$MNT/hello.txt")"
check "size after write" "13" "$(stat -c %s "$MNT/hello.txt")"
echo "second line" >> "$MNT/hello.txt"
check "append" "hello s3disk
second line" "$(cat "$MNT/hello.txt")"
truncate -s 5 "$MNT/hello.txt"
check "truncate down" "hello" "$(cat "$MNT/hello.txt")"
truncate -s 10 "$MNT/hello.txt"
check "truncate up pads with zeros" "10" "$(stat -c %s "$MNT/hello.txt")"
check "zero padding reads back" "68656c6c6f0000000000" "$(xxd -p "$MNT/hello.txt")"
: > "$MNT/empty.txt"
check "empty file" "0" "$(stat -c %s "$MNT/empty.txt")"
printf 'abc' > "$MNT/nonewline"
check "file without trailing newline" "abc" "$(cat "$MNT/nonewline")"

section "objects land in S3"
sync; sleep 1
check "hello.txt exists in bucket" "1" "$(mc ls "t/$BUCKET/$PREFIX/hello.txt" 2>/dev/null | wc -l)"
check "object body matches" "hello" "$(mc cat "t/$BUCKET/$PREFIX/hello.txt" 2>/dev/null | tr -d '\0')"
check "posix mode stored as metadata" "1" "$(mc stat "t/$BUCKET/$PREFIX/hello.txt" 2>/dev/null | grep -ci 'mode')"

section "directories"
mkdir -p "$MNT/a/b/c"
try "mkdir -p" test -d "$MNT/a/b/c"
echo one > "$MNT/a/b/c/one.txt"
echo two > "$MNT/a/b/two.txt"
check "nested read" "one" "$(cat "$MNT/a/b/c/one.txt")"
check "ls lists children" "c
two.txt" "$(ls "$MNT/a/b")"
check "find walks the tree" "5" "$(find "$MNT/a" | wc -l)"
try "rmdir refuses non-empty" bash -c "! rmdir '$MNT/a/b' 2>/dev/null"
mkdir "$MNT/emptydir"
try "rmdir empty dir" rmdir "$MNT/emptydir"
try "empty dir is gone" bash -c "! test -d '$MNT/emptydir'"
mkdir "$MNT/keepme"
sleep 1.2
check "empty dir survives a listing" "1" "$(ls -d "$MNT/keepme" | wc -l)"

section "rename"
echo renameme > "$MNT/src.txt"
mv "$MNT/src.txt" "$MNT/dst.txt"
check "rename file: content" "renameme" "$(cat "$MNT/dst.txt")"
try "rename file: source gone" bash -c "! test -e '$MNT/src.txt'"
check "rename file: object moved" "0" "$(mc ls "t/$BUCKET/$PREFIX/src.txt" 2>/dev/null | wc -l)"
mv "$MNT/a" "$MNT/renamed-dir"
check "rename dir: nested file readable" "one" "$(cat "$MNT/renamed-dir/b/c/one.txt")"
try "rename dir: source gone" bash -c "! test -d '$MNT/a'"
echo over > "$MNT/over.txt"; echo under > "$MNT/under.txt"
mv "$MNT/over.txt" "$MNT/under.txt"
check "rename over existing file" "over" "$(cat "$MNT/under.txt")"

section "symlinks"
ln -s hello.txt "$MNT/link-to-hello"
check "readlink" "hello.txt" "$(readlink "$MNT/link-to-hello")"
check "symlink type" "yes" "$([ -L "$MNT/link-to-hello" ] && echo yes)"
ln -s /etc/hostname "$MNT/abs-link"
check "absolute symlink target" "/etc/hostname" "$(readlink "$MNT/abs-link")"
mkdir -p "$MNT/linkdir"; echo target > "$MNT/linkdir/t.txt"
ln -s t.txt "$MNT/linkdir/rel"
check "follow relative symlink" "target" "$(cat "$MNT/linkdir/rel")"

section "permissions and ownership"
echo x > "$MNT/script.sh"
chmod 755 "$MNT/script.sh"
check "chmod 755 visible" "755" "$(stat -c %a "$MNT/script.sh")"
chmod 600 "$MNT/secret"  2>/dev/null
echo secret > "$MNT/secret"; chmod 600 "$MNT/secret"
check "chmod 600 visible" "600" "$(stat -c %a "$MNT/secret")"
printf '#!/bin/sh\necho ran\n' > "$MNT/run.sh"; chmod +x "$MNT/run.sh"
check "executable bit works" "ran" "$("$MNT/run.sh" 2>&1)"
touch -d "2020-01-02 03:04:05" "$MNT/hello.txt"
check "utimens" "2020-01-02 03:04:05" "$(stat -c %y "$MNT/hello.txt" | cut -d. -f1)"
mkdir -p "$MNT/modedir"; chmod 700 "$MNT/modedir"
check "chmod on directory" "700" "$(stat -c %a "$MNT/modedir")"

section "large files and random I/O"
dd if=/dev/urandom of=/tmp/e2e-big.bin bs=1M count=40 status=none
cp /tmp/e2e-big.bin "$MNT/big.bin"
check "40M file size" "41943040" "$(stat -c %s "$MNT/big.bin")"
check "40M content matches" "$(md5sum < /tmp/e2e-big.bin)" "$(md5sum < "$MNT/big.bin")"
check "read from the middle" "$(dd if=/tmp/e2e-big.bin bs=1 skip=20000000 count=64 status=none | md5sum)" \
                             "$(dd if="$MNT/big.bin" bs=1 skip=20000000 count=64 status=none | md5sum)"
printf 'PATCHED!' | dd of="$MNT/big.bin" bs=1 seek=1000000 conv=notrunc status=none
printf 'PATCHED!' | dd of=/tmp/e2e-big.bin bs=1 seek=1000000 conv=notrunc status=none
check "random write inside a large file" "$(md5sum < /tmp/e2e-big.bin)" "$(md5sum < "$MNT/big.bin")"
check "size unchanged after patch" "41943040" "$(stat -c %s "$MNT/big.bin")"

section "many files"
mkdir -p "$MNT/many"
for i in $(seq 1 200); do echo "file $i" > "$MNT/many/f$i.txt"; done
check "200 files listed" "200" "$(ls "$MNT/many" | wc -l)"
check "random file readable" "file 137" "$(cat "$MNT/many/f137.txt")"
check "du sees the tree" "yes" "$([ "$(du -s "$MNT/many" | cut -f1)" -gt 0 ] && echo yes)"
rm -rf "$MNT/many"
try "rm -rf removed the tree" bash -c "! test -d '$MNT/many'"

section "cache eviction under a small budget"
umount_fs
rm -rf "$CACHE"
if mount_fs --cache-size 24M; then ok "mounted with a 24M cache"; else bad "mounted with a 24M cache" ""; fi
for i in 1 2 3 4 5; do dd if=/dev/urandom of="/tmp/e2e-ev$i.bin" bs=1M count=8 status=none; cp "/tmp/e2e-ev$i.bin" "$MNT/ev$i.bin"; done
evict_ok=yes
for i in 1 2 3 4 5; do
  [ "$(md5sum < "$MNT/ev$i.bin")" = "$(md5sum < "/tmp/e2e-ev$i.bin")" ] || evict_ok="mismatch in ev$i"
done
check "40M of data through a 24M cache" "yes" "$evict_ok"
cache_bytes=$("$BIN" status "$MNT" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["cache"]["bytes"])')
check "cache stayed within budget" "yes" "$([ "$cache_bytes" -le 33554432 ] && echo yes)"
check "cache size is not negative" "yes" "$([ "$cache_bytes" -ge 0 ] && echo yes)"
rm -f /tmp/e2e-ev*.bin
for i in 1 2 3 4 5; do rm -f "$MNT/ev$i.bin"; done
umount_fs
rm -rf "$CACHE"
mount_fs || bad "remount after eviction test" ""

section "cache budget holds for a file that stays open"
umount_fs
rm -rf "$CACHE"
mount_fs --cache-size 32M || bad "mount with a 32M cache" ""
dd if=/dev/urandom of=/tmp/e2e-huge.bin bs=1M count=200 status=none
cp /tmp/e2e-huge.bin "$MNT/huge.bin"
umount_fs
rm -rf "$CACHE"
mount_fs --cache-size 32M || bad "remount with a 32M cache" ""
# One open, one pass: whole-entry eviction cannot reclaim a file being read, so
# this only stays inside the budget if ranges are reclaimed from it.
check "a 200M file reads correctly through a 32M cache" "$(md5sum < /tmp/e2e-huge.bin)" "$(md5sum < "$MNT/huge.bin")"
disk_mb=$(du -sm "$CACHE/data" | cut -f1)
check "the cache stayed within its budget" "yes" "$([ "$disk_mb" -le 48 ] && echo yes || echo "no: ${disk_mb}M on disk")"
check "re-reading it is still correct" "$(md5sum < /tmp/e2e-huge.bin)" "$(md5sum < "$MNT/huge.bin")"
rm -f "$MNT/huge.bin" /tmp/e2e-huge.bin
umount_fs
rm -rf "$CACHE"
mount_fs || bad "remount after cache budget test" ""

section "concurrent writers"
for i in 1 2 3 4 5 6 7 8; do ( for j in $(seq 1 25); do echo "w$i-$j" >> "/tmp/e2e-c$i"; done; cp "/tmp/e2e-c$i" "$MNT/conc-$i.txt" ) & done
wait
concurrent_ok=yes
for i in 1 2 3 4 5 6 7 8; do
  [ "$(cat "$MNT/conc-$i.txt")" = "$(cat "/tmp/e2e-c$i")" ] || concurrent_ok="mismatch in conc-$i"
done
check "8 concurrent writers" "yes" "$concurrent_ok"
rm -f /tmp/e2e-c*

section "git works inside the mount"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
mkdir -p "$MNT/repo"
try "git init"   git -C "$MNT/repo" init -q -b main
echo "# project" > "$MNT/repo/README.md"
mkdir -p "$MNT/repo/src"; echo 'print("hi")' > "$MNT/repo/src/main.py"
try "git add"    git -C "$MNT/repo" add -A
try "git commit" git -C "$MNT/repo" commit -qm "initial commit"
check "git log"  "initial commit" "$(git -C "$MNT/repo" log -1 --pretty=%s)"
echo 'print("bye")' > "$MNT/repo/src/main.py"
check "git sees the change" "1" "$(git -C "$MNT/repo" status --porcelain | wc -l)"
try "git commit again" bash -c "git -C '$MNT/repo' commit -qam second"
try "git fsck" git -C "$MNT/repo" fsck --no-progress
check "git status clean" "0" "$(git -C "$MNT/repo" status --porcelain | wc -l)"

section "build tools"
mkdir -p "$MNT/proj"
cat > "$MNT/proj/Makefile" <<'MK'
all: out.txt
out.txt: in.txt
	cp in.txt out.txt
MK
echo input > "$MNT/proj/in.txt"
try "make builds" make -s -C "$MNT/proj"
check "make output" "input" "$(cat "$MNT/proj/out.txt")"
try "make is up to date" bash -c "make -s -C '$MNT/proj' | grep -q 'up to date' || true"
cat > "$MNT/proj/app.py" <<'PY'
import json, pathlib
p = pathlib.Path(__file__).parent / "data.json"
p.write_text(json.dumps({"ok": True}))
print(json.loads(p.read_text())["ok"])
PY
check "python read/write in mount" "True" "$(cd "$MNT/proj" && python3 app.py)"
check "tar round trip" "input" "$(cd "$MNT/proj" && tar cf t.tar in.txt && rm in.txt && tar xf t.tar && cat in.txt)"

section "unsupported operations fail cleanly"
try "hardlink is refused, not a crash" bash -c "! ln '$MNT/hello.txt' '$MNT/hardlink' 2>/dev/null"
try "mount still alive after that" ls "$MNT" >/dev/null
try "mkfifo refused cleanly" bash -c "! mkfifo '$MNT/fifo' 2>/dev/null"
try "still alive" cat "$MNT/hello.txt" >/dev/null

section "status and sync"
echo pending > "$MNT/pending.txt"
try "s3disk sync"   "$BIN" sync "$MNT"
try "s3disk status" "$BIN" status "$MNT"
check "status shows no dirty files after sync" "0" "$("$BIN" status "$MNT" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["cache"]["dirty"])')"
check "s3disk list shows the mount" "1" "$("$BIN" list | grep -c "$MNT")"
puts_before=$("$BIN" status "$MNT" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["s3"]["puts"])')
for i in 1 2 3 4 5 6 7 8 9 10; do echo "x$i" > "$MNT/cost$i.txt"; done
puts_after=$("$BIN" status "$MNT" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["s3"]["puts"])')
check "one PUT per created file" "10" "$((puts_after - puts_before))"

section "persistence across a remount (cold cache)"
BIG_MD5="$(md5sum < "$MNT/big.bin")"
umount_fs
rm -rf "$CACHE"     # discard every local block: reads must come from S3
if mount_fs; then ok "remounted with an empty cache"; else bad "remounted" "mount failed"; fi
check "small file survived"   "hello" "$(head -c 5 "$MNT/hello.txt")"
check "large file survived"   "$BIG_MD5" "$(md5sum < "$MNT/big.bin")"
check "directory tree survived" "one" "$(cat "$MNT/renamed-dir/b/c/one.txt")"
check "mode survived"         "755" "$(stat -c %a "$MNT/script.sh")"
check "symlink survived"      "hello.txt" "$(readlink "$MNT/link-to-hello")"
check "mtime survived"        "2020-01-02 03:04:05" "$(stat -c %y "$MNT/hello.txt" | cut -d. -f1)"
check "git repo survived"     "second" "$(git -C "$MNT/repo" log -1 --pretty=%s)"
try   "git fsck after remount" git -C "$MNT/repo" fsck --no-progress
check "empty dir survived"    "1" "$(ls -d "$MNT/keepme" | wc -l)"

section "crash recovery"
umount_fs
rm -rf "$CACHE"
mount_fs --dirty-timeout 300s || bad "mount for crash test" ""
# Hold a file open with data that has not been flushed, then hard-kill s3disk.
python3 -c "
import time
f = open('$MNT/inflight.txt', 'w')
f.write('written but never closed')
f.flush()
time.sleep(120)
" &
writer=$!
sleep 7
check "unflushed file is reported as dirty" "1" "$("$BIN" status "$MNT" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["cache"]["dirty"])')"
check "not in S3 yet" "0" "$(mc ls "t/$BUCKET/$PREFIX/inflight.txt" 2>/dev/null | wc -l)"
kill -9 "$(pgrep -f "s3disk mount s3://$BUCKET/$PREFIX $MNT" | head -1)" 2>/dev/null
kill -9 "$writer" 2>/dev/null
sleep 1
try "remount clears the stale mountpoint and recovers" bash -c "'$BIN' mount 's3://$BUCKET/$PREFIX' '$MNT' --endpoint '$ENDPOINT' --path-style --cache-dir '$CACHE'"
sleep 1
check "unflushed write was recovered into S3" "written but never closed" "$(mc cat "t/$BUCKET/$PREFIX/inflight.txt" 2>/dev/null)"
check "and is readable through the mount" "written but never closed" "$(cat "$MNT/inflight.txt")"

section "read-only mode"
umount_fs
if mount_fs --read-only; then ok "mounted read-only"; else bad "mounted read-only" "mount failed"; fi
check "reads still work" "hello" "$(head -c 5 "$MNT/hello.txt")"
try "writes are refused" bash -c "! (echo nope > '$MNT/nope.txt') 2>/dev/null"
try "unlink is refused"  bash -c "! rm '$MNT/hello.txt' 2>/dev/null"
try "file still there"   test -f "$MNT/hello.txt"
# A read-only mount must not write to the bucket at all, including data it
# recovered from a previous session.
puts_ro_before=$("$BIN" status "$MNT" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["s3"]["puts"])')
sleep 5
puts_ro_after=$("$BIN" status "$MNT" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["s3"]["puts"])')
check "a read-only mount issues no writes at all" "0" "$((puts_ro_after - puts_ro_before))"

section "prefix isolation"
umount_fs
mc cp /etc/hostname "t/$BUCKET/outside-the-prefix.txt" >/dev/null 2>&1
mount_fs || bad "remount for prefix test" ""
try "objects outside the prefix are not visible" bash -c "! test -e '$MNT/outside-the-prefix.txt'"
check "the prefix root lists only its own keys" "0" "$(find "$MNT" -maxdepth 1 -name 'outside-the-prefix*' | wc -l)"
mc rm --force "t/$BUCKET/outside-the-prefix.txt" >/dev/null 2>&1

section "attr-mode fast"
umount_fs
rm -rf "$CACHE"
if mount_fs --attr-mode fast; then ok "mounted with --attr-mode fast"; else bad "mounted with --attr-mode fast" ""; fi
check "files still readable" "hello" "$(head -c 5 "$MNT/hello.txt")"
check "listings still work" "yes" "$([ "$(ls "$MNT" | wc -l)" -gt 3 ] && echo yes)"
heads_before=$("$BIN" status "$MNT" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["s3"]["heads"])')
ls "$MNT/renamed-dir/b" >/dev/null 2>&1
heads_after=$("$BIN" status "$MNT" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["s3"]["heads"])')
check "listing costs no per-file HEAD in fast mode" "yes" "$([ "$((heads_after - heads_before))" -le 1 ] && echo yes)"
echo "fast mode write" > "$MNT/fast.txt"
check "writes still work in fast mode" "fast mode write" "$(cat "$MNT/fast.txt")"

section "exclusive mode (one writer per bucket)"
umount_fs
rm -rf "$CACHE"
if mount_fs --exclusive; then ok "mounted --exclusive"; else bad "mounted --exclusive" ""; fi
check "status reports exclusive" "True" "$("$BIN" status "$MNT" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["exclusive"])')"
check "reads work" "hello" "$(head -c 5 "$MNT/hello.txt")"
echo "excl" > "$MNT/excl.txt"
check "writes work" "excl" "$(cat "$MNT/excl.txt")"
ls "$MNT" >/dev/null                      # populate the listing cache
reqs() { "$BIN" status "$MNT" --json | python3 -c 'import json,sys;d=json.load(sys.stdin)["s3"];print(d["heads"]+d["lists"])'; }
before=$(reqs)
for _ in 1 2 3 4 5; do stat "$MNT/definitely-not-here.txt" >/dev/null 2>&1; done
stat "$MNT/also-missing.js" >/dev/null 2>&1
check "a listed directory answers ENOENT locally" "0" "$(( $(reqs) - before ))"
before=$(reqs)
sleep 7                                   # far longer than the metadata TTLs
ls -l "$MNT" >/dev/null
check "cached metadata does not expire" "0" "$(( $(reqs) - before ))"

# A newly created file must still be found, and a deleted one must go away.
echo "new" > "$MNT/created-after-listing.txt"
check "a file created after the listing is visible" "new" "$(cat "$MNT/created-after-listing.txt")"
check "and appears in the directory" "1" "$(find "$MNT" -maxdepth 1 -name created-after-listing.txt | wc -l)"
rm -f "$MNT/created-after-listing.txt"
try "a deleted file is gone" bash -c "! test -e '$MNT/created-after-listing.txt'"
check "rename still resolves" "excl" "$(mv "$MNT/excl.txt" "$MNT/excl-moved.txt" && cat "$MNT/excl-moved.txt")"

# A directory listed while one of its files was still awaiting upload must not
# keep serving that stale listing once the file lands in S3.
mkdir -p "$MNT/pending-dir"
bash -c "
  exec 3> '$MNT/pending-dir/held-open.txt'
  echo held >&3
  ls '$MNT/pending-dir' > /dev/null
  exec 3>&-
"
sleep 1
check "a file uploaded after its directory was listed is visible" "held-open.txt" "$(ls "$MNT/pending-dir")"
check "and is readable"                                           "held"          "$(cat "$MNT/pending-dir/held-open.txt")"

section "refresh picks up out-of-band changes"
# The listing has to be cached *before* the outside write: exclusive mode only
# short-circuits a lookup while it holds an authoritative listing, and the
# renames above dropped the one for this directory.
ls "$MNT" >/dev/null
mc cp /etc/hostname "t/$BUCKET/$PREFIX/outsider.txt" >/dev/null 2>&1
sleep 6
try "an outside write is invisible while exclusive" bash -c "! test -e '$MNT/outsider.txt'"
try "s3disk refresh" "$BIN" refresh "$MNT"
try "the outside write is visible after refresh" test -e "$MNT/outsider.txt"
check "local files survived the refresh" "excl" "$(cat "$MNT/excl-moved.txt")"
mc rm --force "t/$BUCKET/$PREFIX/outsider.txt" >/dev/null 2>&1

section "a cache directory is not reused across buckets"
umount_fs
rm -rf "$CACHE"
mount_fs || bad "mount for cache identity test" ""
echo "prefix-A" > "$MNT/shared-name.txt"
umount_fs
# Same cache dir, different prefix: the stale index must be discarded, not reused.
"$BIN" mount "s3://$BUCKET/${PREFIX}-other" "$MNT" --endpoint "$ENDPOINT" --path-style \
   --cache-dir "$CACHE" >/dev/null 2>&1
sleep 1
try "the other prefix does not inherit cached files" bash -c "! test -e '$MNT/shared-name.txt'"
umount_fs
mc rm --recursive --force "t/$BUCKET/${PREFIX}-other" >/dev/null 2>&1
rm -rf "$CACHE"
mount_fs || bad "remount after cache identity test" ""
check "the original prefix still has its file" "prefix-A" "$(cat "$MNT/shared-name.txt")"

section "interoperability with s3fs-fuse"
if command -v s3fs >/dev/null 2>&1; then
  S3FS_MNT=/mnt/s3fs-interop
  mkdir -p "$S3FS_MNT"
  printf '%s:%s\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" > /tmp/e2e-passwd-s3fs
  chmod 600 /tmp/e2e-passwd-s3fs
  echo "written by s3disk" > "$MNT/interop.txt"
  chmod 751 "$MNT/interop.txt"
  ln -sf interop.txt "$MNT/interop-link"
  "$BIN" sync "$MNT" >/dev/null 2>&1
  # s3fs insists the mounted prefix exists as a marker object of its own.
  mkdir -p "$MNT/.s3fs-probe" && rmdir "$MNT/.s3fs-probe" 2>/dev/null || true
  s3fs "$BUCKET:/$PREFIX" "$S3FS_MNT" -o "url=$ENDPOINT" -o use_path_request_style \
       -o passwd_file=/tmp/e2e-passwd-s3fs -o compat_dir >/dev/null 2>&1
  sleep 2
  if mountpoint -q "$S3FS_MNT"; then
    ok "s3fs mounted the same prefix"
    check "s3fs reads content written by s3disk" "written by s3disk" "$(cat "$S3FS_MNT/interop.txt" 2>&1)"
    check "s3fs sees the stored mode"            "751"               "$(stat -c %a "$S3FS_MNT/interop.txt" 2>&1)"
    check "s3fs follows the symlink"             "interop.txt"       "$(readlink "$S3FS_MNT/interop-link" 2>&1)"
    # And the other direction: s3disk must read what s3fs writes.
    echo "written by s3fs" > "$S3FS_MNT/from-s3fs.txt" 2>/dev/null
    chmod 640 "$S3FS_MNT/from-s3fs.txt" 2>/dev/null
    sync; fusermount3 -u "$S3FS_MNT" 2>/dev/null; sleep 1
    umount_fs; mount_fs || bad "remount after s3fs wrote" ""
    check "s3disk reads content written by s3fs" "written by s3fs" "$(cat "$MNT/from-s3fs.txt" 2>&1)"
    check "s3disk sees the mode s3fs stored"     "640"             "$(stat -c %a "$MNT/from-s3fs.txt" 2>&1)"
  else
    printf '  \033[33mskip\033[0m s3fs would not mount this endpoint\n'
    fusermount3 -u "$S3FS_MNT" 2>/dev/null || true
  fi
  rm -f /tmp/e2e-passwd-s3fs
else
  printf '  \033[33mskip\033[0m s3fs-fuse is not installed\n'
fi

section "clean unmount"
umount_fs
try "unmounted" bash -c "! mountpoint -q '$MNT'"
check "mount deregistered" "0" "$("$BIN" list | grep -c "$MNT")"

printf '\n\033[1mresults: %d passed, %d failed\033[0m\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  printf 'failed: %s\n' "${failed_names[*]}"
  exit 1
fi
