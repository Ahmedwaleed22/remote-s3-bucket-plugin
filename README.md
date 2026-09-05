# s3disk

Mount an S3 bucket as a normal filesystem, so tools that expect a disk — editors,
compilers, `git`, `npm`, and coding agents — can work on a project that lives in
object storage.

```bash
s3disk mount s3://my-bucket/project /workspace
cd /workspace && git status && npm install && make
```

It is a FUSE filesystem in the same family as goofys and s3fs-fuse, written for
the case where a *working tree* lives in a bucket: many small files, read and
rewritten constantly, by tools that assume POSIX semantics.

## What it does

- **Reads at block granularity.** Opening a 2 GB file does not download 2 GB.
  Reads fault in 4 MiB blocks with ranged GETs, and sequential readers get
  readahead, so `grep -r`, `tar` and builds stream at network speed.
- **Writes through a local cache.** Writes land on local disk and the object is
  uploaded when the file is closed. Random writes, appends and `truncate` work,
  which plain "stream to S3" mounts cannot do.
- **Keeps POSIX metadata.** Permissions, ownership, timestamps and symlinks are
  stored in object metadata using the same keys as s3fs-fuse, so executable bits
  and `node_modules/.bin` symlinks survive a round trip — and buckets stay
  interoperable with s3fs (see [Interoperability](#interoperability)).
- **Recovers unsaved writes.** The cache index is checkpointed while writes are
  outstanding. If the mount is killed with files still open, the next mount
  uploads what was pending instead of losing it.
- **Exclusive mode.** When one container owns one bucket or prefix — the usual
  setup — the mount is the only writer, so cached metadata can never go stale.
  `--exclusive` stops re-checking it and answers "no such file" from a listed
  directory without a request. On a 2000-file project that turned 4,893 S3
  requests into 22. See [Exclusive mode](#exclusive-mode).
- **Tells you what is happening.** `s3disk status` reports cache hits, pending
  uploads and the exact S3 request counts a workload generated.

### What it is not

S3 is not a filesystem, and no FUSE layer makes it one. The honest limits:

| | |
|---|---|
| **Hard links** | Not supported (`ln` fails with `ENOTSUP`); S3 has no such concept. |
| **Atomic rename** | `rename` is a server-side copy plus a delete. It is not atomic, and renaming a directory costs one copy per object underneath. |
| **Concurrent writers** | Last close wins. Two mounts writing the same file will not merge; use it as a single-writer working tree (which `--exclusive` then makes much faster). |
| **Partial writes to S3** | Every modified file is re-uploaded in full. Appending one line to a 1 GB log rewrites 1 GB. |
| **Special files** | No FIFOs, sockets or device nodes. |
| **Local disk** | Writes are staged in the cache directory before upload, so the largest file you write must fit there. Running out gives the writing process `ENOSPC`, exactly as a real disk would; the mount stays healthy. |
| **Other clients' changes** | Metadata is cached for a few seconds (`--stat-ttl`, `--list-ttl`), so writes made elsewhere appear after that delay. |

If you need a POSIX-complete shared filesystem, use EFS/NFS. If you want a
project in a bucket to behave like a directory, this is the right shape.

## Install

### Container image (recommended)

```bash
make image                    # or: docker build -f docker/Dockerfile -t s3disk:latest .
```

The image builds from source in a clean context, so a fresh checkout with no
local build output produces the same result. It runs on `linux/amd64` and
`linux/arm64`:

```bash
make image-multiarch          # build both and push to a registry
make image-oci                # both, into a local OCI archive, no registry needed
make dist                     # a single-arch tarball: docker load < dist/*.tar.gz
```

`make dist` is the air-gapped route — an 8 MB tarball that `docker load`
installs on any host with Docker and nothing else.

FUSE needs the device and the mount capability:

```bash
docker run --rm -it \
  --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  -e S3DISK_BUCKET=s3://my-bucket/project \
  s3disk:latest -- ls -la /workspace
```

The image is ~30 MB and runs three ways:

| Invocation | Behaviour |
|---|---|
| `docker run … s3disk` | Mounts and stays in the foreground. Use as a sidecar or a standalone mount. `docker stop` flushes and unmounts cleanly. |
| `docker run … s3disk -- CMD ARGS` | Mounts, runs `CMD` with the project at `/workspace`, then flushes and unmounts. |
| `docker run … s3disk doctor \| status \| sync \| version` | Runs that subcommand directly. |

### On a host

```bash
go install github.com/Ahmedwaleed22/remote-s3-bucket-plugin/cmd/s3disk@latest
```

or, from a checkout, which also registers the `mount(8)` helper and the
systemd unit:

```bash
sudo ./install.sh              # builds and installs to /usr/local
s3disk doctor s3://my-bucket   # check FUSE, credentials and access
```

This installs the binary, registers the `mount(8)` helper so `/etc/fstab` entries
work, and drops in the `s3disk@.service` unit. Requires Go 1.24+ to build and the
`fuse3` package at runtime. `sudo ./install.sh --uninstall` reverses it.

## Using it for agents

The intended setup is **one bucket or prefix per container**, with the agent
running in the same container as its mount. Nothing is shared, so there is no
mount propagation to arrange and no coordination between containers — and
because each mount is then the only writer for its data, `--exclusive` applies
(the images turn it on by default).

```bash
docker build -f examples/agent.Dockerfile -t s3disk-agent .   # ~990 MB: git, node, python, build tools

docker run --rm -it \
  --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
  -e S3DISK_BUCKET=s3://my-bucket/project \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  -v s3disk-cache:/var/cache/s3disk \
  s3disk-agent
```

The agent gets a shell in `/workspace` containing the project. Everything it
writes is uploaded as each file is closed; nothing in its toolchain needs to
know about S3. Mounting the cache on a named volume means a restarted container
starts warm instead of re-reading the tree.

This is tested end to end: `git init`, `npm install`, running the code and
committing — then the same bucket mounted in a *fresh* container with an empty
cache, where `git status` is clean, `git fsck` passes and `require()` still
resolves out of `node_modules`.

Give each container its own cache volume. Cache entries are keyed by object
key, not by bucket, so a volume shared between containers on *different* buckets
would be ambiguous — s3disk detects that (it records which bucket and prefix a
cache belongs to) and discards the foreign cache rather than serving the wrong
bytes, but you lose the warm cache each time.

If you do need one mount visible to *other* containers, it has to be propagated
through the host: bind `/mnt/s3` with `propagation: rshared` into both
containers and run `mount --make-rshared /mnt/s3` on the host first. See
`docker-compose.yml`.

### As a system mount

```bash
sudo cp packaging/example.conf /etc/s3disk/project.conf
sudo systemctl enable --now s3disk@project
```

Or in `/etc/fstab`, via the installed `mount.s3disk` helper:

```
my-bucket:project  /srv/project  fuse.s3disk  _netdev,allow-other,cache-size=16G  0 0
```

## Commands

```
s3disk mount  s3://BUCKET[/PREFIX] MOUNTPOINT [options]
s3disk umount MOUNTPOINT [--force] [--no-sync]
s3disk status [MOUNTPOINT]     cache, pending uploads and S3 request counts
s3disk sync   [MOUNTPOINT]     flush every pending write now, and wait
s3disk refresh [MOUNTPOINT]    forget cached metadata after an out-of-band change
s3disk list                    live s3disk mounts
s3disk doctor [s3://BUCKET]    check FUSE, credentials and bucket access
```

`mount` daemonises by default and returns only once the filesystem is actually
usable, so a script can mount and immediately use the path.

```console
$ s3disk status /workspace
mountpoint   /workspace
source       s3://my-bucket/project/
cache dir    /var/cache/s3disk
uptime       11s

cache        176.0 KiB of 8.0 GiB in 214 files, 0 dirty
             0 hits, 214 misses, 0 evictions, 1 uploads
s3 requests  3032 HEAD  276 LIST  214 GET  1 PUT  0 COPY  0 DELETE  0 errors
transferred  176.0 KiB down, 86 B up
```

## Options

Options may appear before or after the positional arguments, and every one of
them also works in `-o` form for `mount(8)` and `/etc/fstab`.

**Connection**

| Option | Default | |
|---|---|---|
| `--endpoint URL` | AWS | S3 endpoint for MinIO, Ceph, R2, Wasabi, … |
| `--region NAME` | `us-east-1` | |
| `--path-style` | off | Required by most S3-compatible servers. |
| `--profile NAME` | | Shared-credentials profile. |
| `--checksums` | off | Send CRC checksums; some S3 clones reject them. |
| `--storage-class`, `--sse`, `--kms-key-id`, `--acl` | | Applied to new objects. |

Credentials come from the standard AWS chain: environment variables, a shared
profile, container credentials, instance roles or web identity.

**Cache**

| Option | Default | |
|---|---|---|
| `--cache-dir PATH` | `~/.cache/s3disk/BUCKET` | Where blocks are kept. |
| `--cache-size SIZE` | `8G` | Budget for cached data. Least recently used clean files are evicted whole; if that is not enough (a single file larger than the budget, held open), cached ranges are released from inside open clean files instead. |
| `--block-size SIZE` | `4M` | Granularity of ranged reads. |
| `--readahead SIZE` | `16M` | Prefetch window for sequential readers. |
| `--persist-cache` | on | Keep the cache across mounts and recover unsaved writes. |

**Metadata**

| Option | Default | |
|---|---|---|
| `--attr-mode full\|fast` | `full` | `full` reads modes, ownership and symlinks with one HEAD per object. `fast` skips it: listings are much quicker, but stored permissions and symlinks made by other clients are not visible. |
| `--attr-workers N` | `32` | Parallel HEADs used to fill a listing. |
| `--uid`, `--gid`, `--file-mode`, `--dir-mode` | current user, `0644`, `0755` | Used for objects with no stored metadata. |
| `--stat-ttl`, `--list-ttl`, `--negative-ttl` | `5s` | How long metadata is cached. Local changes always update the cache immediately; these only govern how fast *other* clients' writes appear. |
| `--sync-metadata` | on | Persist `chmod`/`chown`/`utimens` back to S3. |
| `--exclusive` | off (on in the images) | This mount is the only writer for the bucket/prefix. Cached metadata stops expiring and listed directories answer `ENOENT` locally. Overrides the three TTLs above. |

**Writes**

| Option | Default | |
|---|---|---|
| `--dirty-timeout D` | `3s` | Upload a file that has been dirty this long even while it is still open. |
| `--multipart-threshold`, `--part-size` | `16M` | Multipart upload tuning. |
| `--upload-concurrency N` | `4` | Parallel part uploads. |
| `--read-only` | off | Refuse every modification with `EROFS`, and never issue a write to S3 — including data recovered from a previous mount, which is left on disk for a later read-write mount. |

**Mount**

`--allow-other`, `--foreground`, `--debug`, `--debug-fuse`, `--log-file PATH`.

## How it behaves

**Durability.** A write is in S3 once `close()` returns — `s3disk` uploads on
the last flush of each file descriptor. Files held open longer than
`--dirty-timeout` are uploaded in the background too. `s3disk sync` forces
everything immediately, and unmounting always flushes first.

**Consistency.** A single mount is always consistent with itself: its own
writes are visible immediately, including files that have not been uploaded yet.
Changes made by *other* clients appear after the metadata TTLs expire.

**Crash safety.** The cache index is checkpointed every few seconds while writes
are pending. After a `SIGKILL`, the next mount of the same cache directory
re-uploads what was outstanding and says so in the log. A stale mountpoint from
a killed process is cleared automatically. A read-only mount never performs that
recovery, since it must not write to the bucket at all.

**Disk use.** The cache honours `--cache-size` even while a file is open: when
whole files cannot be evicted, already-read ranges are punched out of open clean
files (they are all still in S3, so a re-read simply refetches). Reading a 300 GB
object through an 8 GB cache is fine; *writing* a file bigger than the cache
directory's free space is not, because writes are staged locally first.

**Requests per operation.** Creating a file is one `PUT`; the empty-file flush
the kernel sends right after `create` is deliberately deferred so files are not
stored twice. Reading a cached file is zero requests. A missing path costs one
`HEAD` plus one `LIST`, cached negatively afterwards.

**Empty directories** exist as zero-byte `dir/` marker objects, the convention
s3fs and goofys use, so `mkdir` survives even with nothing inside.

## Exclusive mode

The metadata TTLs (`--stat-ttl`, `--list-ttl`, `--negative-ttl`) exist for one
reason: to notice writes made by somebody else. When a container owns its own
bucket or folder, there is no somebody else — this mount is the only thing that
can change the data, and it updates its own caches as it does.

`--exclusive` states that, and s3disk then:

- keeps cached attributes and listings until a local operation invalidates them,
  instead of re-reading them every few seconds;
- answers `ENOENT` straight from a listed directory, with no request at all —
  which matters because resolving imports, include paths and `node_modules`
  generates far more misses than hits;
- lets the kernel hold entries and attributes for a minute rather than a second.

Measured on a 2,119-file project (`git` repository plus `node_modules`), walking
the tree twice, loading a module and running `git status`:

| | First walk | Everything after it |
|---|---|---|
| default | 2,654 requests | **4,893** more requests, 12.8 s |
| `--exclusive` | 2,654 requests | **22** more requests, 3.4 s |

The trade-off is exactly what it sounds like: a change made to the bucket by
anything else stays invisible. If that happens — you seed the bucket, or edit an
object directly — run:

```bash
s3disk refresh /workspace
```

which drops the cached metadata and the kernel's copy of it, so the next access
re-reads from S3. Local writes that have not been uploaded yet are kept.

`refresh` takes effect immediately: an exclusive mount deliberately stops the
kernel from caching "no such file" results, because a negative dentry has no
inode to invalidate. Those lookups are still answered without an S3 request —
which is where the cost was — just by s3disk rather than by the kernel.

`--exclusive` is off by default for the binary and on by default in the images
(`S3DISK_EXCLUSIVE=true`), since an image invocation names one bucket for one
container. Set `-e S3DISK_EXCLUSIVE=false` if something else writes to the same
prefix at the same time.

## As a Remote application

s3disk ships as a one-click image in Remote's Applications tab, where it
installs into the project's own container as a `tool`: no port, no proxy
device, just the bucket mounted at a path inside the workspace. The catalog
entry is `installable-images/s3disk/` in the Remote repository; installing it
runs the same `s3disk mount` under a systemd unit, so the tab's stop, start and
uninstall map onto the mount.

## Interoperability

Metadata uses the s3fs-fuse convention (`x-amz-meta-mode`, `uid`, `gid`,
`mtime`, `atime`, `ctime`), and directories are zero-byte `dir/` marker objects
as goofys and s3fs both understand. Both directions are tested:

- **s3disk reads s3fs buckets** as they are — content, permissions and symlinks
  written by s3fs come through unchanged.
- **s3fs reads s3disk buckets** with `-o compat_dir`, which tells s3fs to accept
  `dir/` markers alongside its own directory format. s3fs also insists that the
  prefix you mount exists as a marker object of its own.

Plain S3 tools see exactly what you would expect: `project/src/main.py` in the
filesystem is the object `project/src/main.py` in the bucket, with its normal
content and a guessed `Content-Type`. Nothing is chunked, wrapped or encoded, so
a bucket written through s3disk stays usable by anything else.

## Performance notes

Measured against a MinIO on the same host, so these show the filesystem's own
overhead rather than network latency to a remote bucket:

| Operation | |
|---|---|
| Create 200 small files | 4.5 s (~23 ms each: one `HEAD`, one `LIST`, one `PUT`) |
| Read 200 cached files | 1.2 s (~6 ms each, no S3 requests) |
| Sequential read, 100 MB, cold cache | 0.54 s (~185 MB/s, ranged GETs with readahead) |
| Sequential read, 100 MB, warm cache | 0.03 s (served from local disk) |
| `npm install express` (601 files) | ~10 s |
| `git clone` of a small repository | ~8 s |

Things that help:

- `--exclusive`, whenever this mount is the only writer. It is the single
  largest win available; see the table above.
- `--attr-mode fast` if you do not need stored permissions or symlinks — it
  removes one `HEAD` per file from every directory listing.
- A bigger `--cache-size` so a working tree stays resident.
- A persistent `--cache-dir` (a named volume in Docker) so restarts start warm.
- Raising `--dirty-timeout` for write-heavy bursts, so a file rewritten several
  times is uploaded once.

Things that are slow, inherently: rewriting very large files (the whole object
is re-uploaded), renaming large directories (one copy per object), and the first
walk of a large tree (one `LIST` per directory).

## Troubleshooting

```bash
s3disk doctor s3://my-bucket     # FUSE device, fusermount, credentials, access
s3disk status /workspace         # is anything pending? are requests failing?
s3disk mount … --debug --foreground   # watch it work
```

| Symptom | Cause |
|---|---|
| `/dev/fuse is missing` | Run the container with `--device /dev/fuse --cap-add SYS_ADMIN`. |
| `fusermount: option allow_other only allowed if 'user_allow_other' is set` | Add `user_allow_other` to `/etc/fuse.conf`, or drop `--allow-other`. |
| `transport endpoint is not connected` | A previous mount died. `s3disk mount` clears this automatically; otherwise `fusermount3 -uz PATH`. |
| `InvalidAccessKeyId` against MinIO | Missing `--endpoint`, so the request went to real AWS. |
| `403` on a working bucket | The credentials need `s3:GetObject`, `PutObject`, `DeleteObject` and `ListBucket` on the prefix. |
| Writes appear slowly to other clients | Expected: metadata TTLs. Lower `--stat-ttl`/`--list-ttl`, or run `s3disk sync`. |
| A change made outside the mount is not visible | `--exclusive` is on (the image default). Run `s3disk refresh MOUNTPOINT`, or mount with `-e S3DISK_EXCLUSIVE=false`. |
| A restarted container re-reads everything | Its cache volume was used by a different bucket or prefix, so it was discarded. Give each mount its own cache volume. |

## Development

```bash
make build        # bin/s3disk
make test         # unit tests
make minio        # throwaway MinIO on :9000
make e2e          # 130-assertion end-to-end suite against it
make image        # container image
```

`test/e2e.sh` exercises the real filesystem: POSIX semantics, large-file random
I/O, cache eviction, concurrent writers, `git`, `make`, crash recovery and
persistence across a remount with a cold cache.

## Layout

```
cmd/s3disk/         CLI: mount, umount, status, sync, list, doctor
internal/config/    options, s3:// parsing, mount(8) -o compatibility
internal/s3io/      S3 access: head, list, ranged get, upload, copy, delete
internal/cache/     local block cache, write-back, eviction, crash recovery
internal/s3fs/      the FUSE filesystem and its metadata caches
internal/ctl/       per-mount control socket and mount registry
docker/             image and entrypoint
packaging/          systemd unit and example configuration
```
