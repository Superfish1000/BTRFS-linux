#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
Measure how much free space in a RAID5/6 filesystem is stranded inside
vertical stripes that still hold referenced data.

Why this number matters
-----------------------

Copy-on-write parity would make the RAID5/6 write hole structurally
impossible rather than merely recoverable, but it needs an allocation rule
that never writes into a stripe still holding committed sectors.  The cost
of that rule is exactly the free space it puts out of reach.

The unit is smaller than it first appears.  btrfs computes parity per
*vertical* stripe -- generate_pq_vertical_step() takes one sector from each
data stripe at the same offset, and rmw_assemble_write_bios() already skips
vertical stripes a write does not touch.  So the granule that must stay
immutable is nr_data sectors (12KiB on a four-disk RAID5 at 4KiB sectors),
not the whole nr_data * 64KiB full stripe.

If the stranded fraction is small, an immutable-stripe allocator is
practical and needs no on-disk format change.  If it is large, that whole
family of designs dies on ENOSPC and only variable-width rows remain, which
is a much larger project.  Nobody has measured it.

Usage
-----

    btrfs inspect-internal dump-tree -t chunk  <dev> > chunk.txt
    btrfs inspect-internal dump-tree -t extent <dev> > extent.txt
    raid56_row_occupancy.py chunk.txt extent.txt

Reads dump-tree output rather than the device, so it needs no privileges and
can run on a copy taken elsewhere.
"""

import argparse
import re
import sys
from collections import defaultdict

DEFAULT_STRIPE_LEN = 64 * 1024


class Chunk:
    __slots__ = ("start", "length", "num_stripes", "nr_data", "profile",
                 "stripe_len", "sectorsize")

    def __init__(self, start, length, num_stripes, profile, stripe_len,
                 sectorsize):
        self.start = start
        self.length = length
        self.num_stripes = num_stripes
        self.profile = profile
        self.stripe_len = stripe_len
        self.sectorsize = sectorsize
        nparity = 1 if profile == "RAID5" else 2
        self.nr_data = num_stripes - nparity

    @property
    def full_stripe_len(self):
        return self.nr_data * self.stripe_len


def parse_chunks(path, sectorsize_override=None):
    """Pull the RAID5/6 data chunks out of `dump-tree -t chunk` output."""
    chunks = []
    # The objectid of a chunk key prints as FIRST_CHUNK_TREE, not as a number.
    key_re = re.compile(r"item \d+ key \(\S+ CHUNK_ITEM (\d+)\)")
    len_re = re.compile(r"\blength (\d+)")
    slen_re = re.compile(r"\bstripe_len (\d+)")
    sect_re = re.compile(r"\bsector_size (\d+)")
    num_re = re.compile(r"\bnum_stripes (\d+)")
    type_re = re.compile(r"\btype ([A-Z0-9|]+)")

    cur = None

    def flush():
        if (cur and cur["profile"] in ("RAID5", "RAID6") and cur["num_stripes"]
                and cur["length"]):
            chunks.append(Chunk(cur["start"], cur["length"], cur["num_stripes"],
                                cur["profile"],
                                cur["stripe_len"] or DEFAULT_STRIPE_LEN,
                                sectorsize_override or cur["sectorsize"] or 4096))

    for line in open(path):
        m = key_re.search(line)
        if m:
            flush()
            cur = dict(start=int(m.group(1)), length=None, num_stripes=None,
                       profile=None, stripe_len=None, sectorsize=None)
            continue
        if cur is None:
            continue
        m = len_re.search(line)
        if m and cur["length"] is None:
            cur["length"] = int(m.group(1))
        m = slen_re.search(line)
        if m and cur["stripe_len"] is None:
            cur["stripe_len"] = int(m.group(1))
        m = sect_re.search(line)
        if m and cur["sectorsize"] is None:
            cur["sectorsize"] = int(m.group(1))
        m = type_re.search(line)
        if m:
            t = m.group(1)
            # Only data chunks are interesting; metadata is not allocated
            # by the data allocator this models.
            if "DATA" in t and "RAID5" in t:
                cur["profile"] = "RAID5"
            elif "DATA" in t and "RAID6" in t:
                cur["profile"] = "RAID6"
        m = num_re.search(line)
        if m and cur["num_stripes"] is None:
            cur["num_stripes"] = int(m.group(1))
    flush()
    return chunks


def parse_extents(path):
    """Allocated [start, end) data ranges from `dump-tree -t extent` output."""
    extents = []
    item_re = re.compile(r"item \d+ key \((\d+) (EXTENT_ITEM|METADATA_ITEM) (\d+)\)")
    for line in open(path):
        m = item_re.search(line)
        if not m:
            continue
        start = int(m.group(1))
        # For METADATA_ITEM the offset is the level, not a length; those do
        # not live in data chunks, so they are dropped by the range check.
        if m.group(2) == "METADATA_ITEM":
            continue
        extents.append((start, start + int(m.group(3))))
    extents.sort()
    return extents


def occupancy(chunk, extents):
    """
    Return (live_sectors, free_sectors, stranded_sectors) for one chunk.

    A vertical stripe is live if any of its nr_data sectors is inside an
    allocated extent.  Free sectors inside a live vertical stripe are
    stranded: an allocator forbidden from touching a stripe that holds
    committed data cannot use them.
    """
    sectorsize = chunk.sectorsize
    sectors_per_stripe = chunk.stripe_len // sectorsize
    live = free = stranded = 0

    # Bitmap of allocated sectors within the chunk, by chunk-relative index.
    n_sectors = chunk.length // sectorsize
    allocated = bytearray(n_sectors)
    for estart, eend in extents:
        if eend <= chunk.start or estart >= chunk.start + chunk.length:
            continue
        lo = max(estart, chunk.start) - chunk.start
        hi = min(eend, chunk.start + chunk.length) - chunk.start
        for s in range(lo // sectorsize, (hi + sectorsize - 1) // sectorsize):
            if s < n_sectors:
                allocated[s] = 1

    n_full_stripes = chunk.length // chunk.full_stripe_len
    for i in range(n_full_stripes):
        base = i * chunk.full_stripe_len
        for v in range(sectors_per_stripe):
            members = []
            for d in range(chunk.nr_data):
                off = base + d * chunk.stripe_len + v * sectorsize
                idx = off // sectorsize
                if idx < n_sectors:
                    members.append(allocated[idx])
            if not members:
                continue
            n_live = sum(members)
            live += n_live
            free += len(members) - n_live
            if n_live:
                stranded += len(members) - n_live
    return live, free, stranded


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024 or unit == "TiB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("chunk_dump", help="output of dump-tree -t chunk")
    ap.add_argument("extent_dump", help="output of dump-tree -t extent")
    ap.add_argument("--sectorsize", type=int, default=None,
                    help="override the sector size read from the chunk dump")
    ap.add_argument("--stripe-len", type=int, default=None,
                    help="model the array as if the stripe unit were this, "
                         "instead of the 64KiB the chunk dump records. A "
                         "vertical stripe's members lie stripe_len apart, so "
                         "this is what decides whether free space has to be "
                         "contiguous over nr_data*stripe_len to be usable. At "
                         "--stripe-len equal to the sector size the members "
                         "are contiguous.")
    ap.add_argument("--csv", help="also write the per-block-group rows here,"
                    " ordered by how full the block group is")
    args = ap.parse_args()

    chunks = parse_chunks(args.chunk_dump, args.sectorsize)
    if args.stripe_len:
        kept = []
        dropped = 0
        for c in chunks:
            # A chunk whose length is not a whole number of modelled full
            # stripes cannot be re-gridded, and leaving it in at its real
            # stripe unit would silently mix two granules in one total.
            if c.length % (c.nr_data * args.stripe_len):
                dropped += c.length
                continue
            c.stripe_len = args.stripe_len
            kept.append(c)
        if dropped:
            print(f"excluded {human(dropped)} of chunks whose length is not a "
                  f"whole number of {args.stripe_len}-byte full stripes",
                  file=sys.stderr)
        chunks = kept
    if not chunks:
        print("no RAID5/6 data chunks found", file=sys.stderr)
        return 1
    extents = parse_extents(args.extent_dump)

    totals = defaultdict(int)
    rows = []
    print(f"{'block group':>16} {'profile':>7} {'nr_data':>7} "
          f"{'used':>10} {'free':>10} {'used%':>6} "
          f"{'stranded':>10} {'stranded%':>9} {'if random':>9}")
    for c in chunks:
        live, free, stranded = occupancy(c, extents)
        ss = c.sectorsize
        totals["live"] += live * ss
        totals["free"] += free * ss
        totals["stranded"] += stranded * ss
        pct = (100.0 * stranded / free) if free else 0.0
        # How full this block group is.  Stranding is mostly a function of
        # this, so the rows of one filesystem are already a curve.
        usedpct = (100.0 * live / (live + free)) if (live + free) else 0.0
        # What the same fullness would strand if the live sectors were
        # scattered at random: a vertical stripe of nr_data sectors then
        # holds live data with probability 1 - (1-u)^nr_data, and every free
        # sector in it is stranded.  The gap between this and the measured
        # column is what the allocator's clustering is worth.
        u = usedpct / 100.0
        randpct = 100.0 * (1.0 - (1.0 - u) ** c.nr_data)
        rows.append((c.start, c.profile, c.nr_data, live * ss, free * ss,
                     usedpct, stranded * ss, pct, randpct))
        print(f"{c.start:>16} {c.profile:>7} {c.nr_data:>7} "
              f"{human(live * ss):>10} "
              f"{human(free * ss):>10} {usedpct:>5.1f}% "
              f"{human(stranded * ss):>10} {pct:>8.1f}% {randpct:>8.1f}%")

    if args.csv:
        with open(args.csv, "w") as f:
            f.write("block_group,profile,nr_data,used,free,used_pct,"
                    "stranded,stranded_pct,random_pct\n")
            for r in sorted(rows, key=lambda r: r[5]):
                f.write("%d,%s,%d,%d,%d,%.3f,%d,%.3f,%.3f\n" % r)
        print(f"\nper-block-group rows written to {args.csv}", file=sys.stderr)

    free = totals["free"]
    stranded = totals["stranded"]
    print()
    print(f"total used      {human(totals['live'])}")
    print(f"total free      {human(free)}")
    print(f"  of which stranded in vertical stripes that hold live data:")
    print(f"                {human(stranded)}"
          f"  ({100.0 * stranded / free if free else 0:.1f}% of free)")
    print(f"  usable by an immutable-stripe allocator:")
    print(f"                {human(free - stranded)}")
    print()
    print("A small stranded fraction means an immutable-stripe allocator is")
    print("practical with no on-disk format change.  A large one means that")
    print("family of designs runs out of space and only variable-width rows")
    print("remain.  Read the per-block-group rows before the total: stranding")
    print("rises steeply with how full a block group is, so one filesystem's")
    print("rows already show the shape of the curve.  The last column is what")
    print("the same fullness would strand with the live sectors scattered at")
    print("random; the distance below it is what btrfs's clustered allocator")
    print("is already worth to this design.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
