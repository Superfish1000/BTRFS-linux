#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
Age a filesystem the way a real one ages, so that measuring its free space
says something.

A freshly packed filesystem strands nothing: the allocator laid every extent
down in order and there are no holes.  The number raid56_row_occupancy.py is
after -- free space trapped inside vertical stripes that still hold live
sectors -- only appears once files have been deleted and rewritten under
copy-on-write.  So this writes, deletes and overwrites in a mixture chosen to
resemble ordinary use rather than to maximise or minimise the result:

  * a heavy tail of small files, which is what most directories hold,
  * a few large ones, which is where most of the bytes are,
  * deletions of whole files, which free scattered extents,
  * small overwrites of surviving files, which under COW free a sector here
    and allocate one there -- the pattern that actually perforates stripes.

It fills the filesystem first and then churns at that fullness: an\nalmost-empty filesystem strands nothing, because the allocator never has to\nreuse a stripe that already holds data.\n\nDeterministic given --seed, so a measurement can be repeated.
"""

import argparse
import os
import random
import sys

KIB = 1024
MIB = 1024 * KIB


def size_sample(rng):
    r = rng.random()
    if r < 0.70:
        return rng.randrange(4 * KIB, 64 * KIB, 4 * KIB)
    if r < 0.95:
        return rng.randrange(64 * KIB, MIB, 4 * KIB)
    return rng.randrange(MIB, 8 * MIB, 4 * KIB)


def write_file(path, size, rng):
    buf = rng.randbytes(min(size, MIB))
    with open(path, "wb") as f:
        left = size
        while left > 0:
            n = min(left, len(buf))
            f.write(buf[:n])
            left -= n
    return size


def overwrite(path, rng):
    try:
        size = os.path.getsize(path)
    except OSError:
        return 0
    if size <= 4 * KIB:
        return 0
    n = min(rng.randrange(4 * KIB, 16 * KIB + 1, 4 * KIB), size)
    off = rng.randrange(0, size - n + 1, 4 * KIB) if size > n else 0
    with open(path, "r+b") as f:
        f.seek(off)
        f.write(rng.randbytes(n))
    return n


def data_used_frac(root):
    """Rough fullness of the filesystem holding @root."""
    st = os.statvfs(root)
    total = st.f_blocks * st.f_frsize
    avail = st.f_bavail * st.f_frsize
    if total == 0:
        return 0.0
    return 1.0 - (avail / total)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--rounds", type=int, default=12)
    ap.add_argument("--fill", type=float, default=0.75,
                    help="fullness to age at, as a fraction of the filesystem")
    ap.add_argument("--band", type=float, default=0.10,
                    help="how far below --fill a round frees before refilling")
    ap.add_argument("--overwrite-frac", type=float, default=0.25)
    ap.add_argument("--max-bytes", type=int, default=0,
                    help="stop after writing this many MiB in total (0: no limit)")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    os.makedirs(args.root, exist_ok=True)
    files = []
    written = 0
    seq = 0
    limit = args.max_bytes * MIB
    low = max(0.0, args.fill - args.band)

    def fill_to(target):
        """Write files until the filesystem is @target full."""
        nonlocal written, seq
        d = os.path.join(args.root, "d%02d" % (seq // 500))
        os.makedirs(d, exist_ok=True)
        while data_used_frac(args.root) < target:
            if limit and written >= limit:
                return False
            seq += 1
            if seq % 500 == 0:
                d = os.path.join(args.root, "d%02d" % (seq // 500))
                os.makedirs(d, exist_ok=True)
            p = os.path.join(d, "f%06d" % seq)
            try:
                written += write_file(p, size_sample(rng), rng)
            except OSError as e:
                print("write stopped: %s" % e)
                return False
            files.append(p)
        return True

    def free_to(target):
        """Delete whole files until the filesystem is @target full."""
        rng.shuffle(files)
        n = 0
        while files and data_used_frac(args.root) > target:
            p = files.pop()
            try:
                os.unlink(p)
            except OSError:
                pass
            # btrfs frees the extents through delayed refs, so statvfs lags
            # behind the unlinks.  Without this the loop reads a filesystem
            # that still looks full and deletes far more than it was asked
            # to, which defeats the point: a filesystem emptied in bulk gets
            # whole block groups back and stops looking aged at all.
            n += 1
            if n % 16 == 0:
                os.sync()
        os.sync()

    # Phase 1: fill up.  A filesystem with plenty of virgin space strands
    # nothing, because the allocator never has to reuse a perforated stripe;
    # the number only means something once it is reasonably full.
    fill_to(args.fill)
    os.sync()
    print("filled: %d files, %.1f%% full, %d MiB written"
          % (len(files), 100 * data_used_frac(args.root), written // MIB))

    # Phase 2: churn at that fullness.  Delete, refill, and overwrite in
    # place, which is what perforates stripes under copy-on-write.
    for rnd in range(args.rounds):
        free_to(low)
        for p in rng.sample(files, min(len(files), int(len(files) * args.overwrite_frac))):
            try:
                written += overwrite(p, rng)
            except OSError:
                pass
        os.sync()
        if not fill_to(args.fill):
            break
        os.sync()
        print("round %d: %d files live, %.1f%% full, %d MiB written"
              % (rnd, len(files), 100 * data_used_frac(args.root), written // MIB))

    os.sync()
    print("aged: %d files live, %.1f%% full, %d MiB written total"
          % (len(files), 100 * data_used_frac(args.root), written // MIB))
    return 0


if __name__ == "__main__":
    sys.exit(main())
