# How much free space does copy-on-write parity cost?

*RAID5/6 stranded free space, measured. 2026-09-07.*

## The question

Every design that would make the RAID5/6 write hole structurally impossible
rather than merely recoverable -- sealed rows, immutable stripes, copy-on-write
parity, whatever it gets called -- needs one allocation rule:

> never write into a stripe that still holds committed sectors.

Follow that rule and a crash during a write cannot damage data that was already
there, because the write never touches a stripe holding any. No log, no
journal, no recovery pass. The rule *is* the design.

The rule's price is the free space it puts out of reach: free sectors sitting in
a stripe that some live sector is also in. If that is a small fraction, an
immutable-stripe allocator is practical and needs no on-disk format change. If
it is most of the free space, the filesystem hits ENOSPC while `df` still
reports gigabytes, and the whole family dies -- leaving only variable-width
rows, a far larger project.

Nobody had measured it. This is the measurement.

## What is being measured

The granule is smaller than "a stripe" suggests. btrfs computes parity per
*vertical* stripe: `generate_pq_vertical_step()` takes one sector from each data
stripe at the same offset, and `rmw_assemble_write_bios()` already skips
vertical stripes a write does not touch. So what must stay immutable is
`nr_data` sectors -- 12 KiB on a four-disk RAID5 at 4 KiB sectors -- not the
whole `nr_data * 64 KiB` full stripe. Writing into a free vertical stripe of an
otherwise-occupied full stripe is safe, and counts as usable.

A vertical stripe is *live* if any of its `nr_data` sectors falls inside an
allocated extent. Free sectors inside a live vertical stripe are *stranded*.

`tools/testing/btrfs/raid56_row_occupancy.py` computes this from
`btrfs inspect-internal dump-tree -t chunk` and `-t extent` output, so it needs
no privileges and runs against a dump taken from someone else's array.
`tools/testing/btrfs/uml/age.sh` produces filesystems worth measuring: a freshly
packed one strands nothing, because the allocator never had to reuse a
perforated stripe. Each is filled to a target fullness inside UML and then
churned there -- delete whole files, refill, overwrite survivors in place, which
is what copy-on-write perforates stripes with.

## Results

| profile | devices | nr_data | aged at | free | stranded | per-block-group range | random-placement bound |
|---|---|---|---|---|---|---|---|
| RAID5 | 4 | 3 | 80.7% full | 1.3 GiB | **227 MiB (17.2%)** | 0.3% – 60.4% | 64% – 99.8% |
| RAID6 | 4 | 2 | 80.9% full | 908 MiB | **66 MiB (7.3%)** | 0.8% – 20.1% | 53% – 97.0% |
| RAID5 | 4 | 3 | 92.5% full | 617 MiB | **294 MiB (47.6%)** | 30.5% – 67.6% | 99.1% – 99.9% |

The RAID5 rows at 80.7% full, in full:

```
     block group profile nr_data       used       free  used%   stranded stranded% if random
       298844160   RAID5       3  321.5 MiB  292.7 MiB  52.3%   65.7 MiB     22.5%     89.2%
       942931968   RAID5       3  759.1 MiB  104.9 MiB  87.9%   63.3 MiB     60.4%     99.8%
      1848901632   RAID5       3  742.5 MiB  121.5 MiB  85.9%   47.5 MiB     39.1%     99.7%
      2754871296   RAID5       3  731.1 MiB  132.9 MiB  84.6%   27.8 MiB     20.9%     99.6%
      3660840960   RAID5       3  707.0 MiB  157.0 MiB  81.8%   12.6 MiB      8.0%     99.4%
      4566810624   RAID5       3  651.7 MiB  212.3 MiB  75.4%    9.0 MiB      4.2%     98.5%
      5472780288   RAID5       3  119.8 MiB  295.0 MiB  28.9%    1.0 MiB      0.3%     64.0%
```

The 92.5% filesystem also grew two `nr_data 1` block groups, because the devices
filled unevenly and btrfs made two-device RAID5 chunks out of what was left.
Those strand nothing by construction -- a vertical stripe of one sector cannot
have a live neighbour -- and they are excluded from the range above.

## What it means

### At a normal operating point the rule is affordable

At ~81% full the rule costs 17% of the remaining free space on RAID5 and 7% on
RAID6 -- 227 MiB of 1.3 GiB, 66 MiB of 908 MiB. Paying it is equivalent to
running the filesystem one to three percentage points fuller than it really is.

That is not survival by a narrow margin. The result that would have killed the
family -- most of the free space unreachable -- is not what happens.

### But the price is steeply non-linear in fullness

At 92.5% full the same profile strands 47.6%. The two RAID5 measurements differ
only in how full the filesystem was kept, and the tax nearly triples. The
per-block-group rows show the same curve inside a single filesystem: 0.3% in a
block group 29% full, 60.4% in one 88% full.

So an immutable-stripe allocator is affordable only if block groups are kept off
the top of that curve. It would not in practice pay 17%: it would skip the block
groups where the rule bites and allocate in the ones where it does not, which is
exactly what block-group reclaim exists to make possible. btrfs already has that
machinery (`/sys/fs/btrfs/<uuid>/allocation/data/bg_reclaim_threshold`) and it is
off by default on non-zoned filesystems. **The feasibility of copy-on-write
parity turns on a knob that already exists**, not on a new on-disk format. That
is the most useful thing this measurement has to say.

### It is affordable because of the allocator, not the geometry

The last column is what the same fullness would strand if live sectors were
scattered at random: a vertical stripe of `nr_data` sectors holds live data with
probability `1 - (1-u)^nr_data`, and every free sector in such a stripe is lost.
That bound runs from 53% to 99.9% across these filesystems. The measurements run
from 0.3% to 67.6%.

Almost all of the free space an immutable-stripe allocator would keep is free
only because `find_free_extent()` already packs live data into clusters instead
of spreading it. The design is not standing on the geometry of RAID5/6; it is
standing on btrfs's allocation policy. Worth writing down, because an allocator
change made for unrelated reasons could move this number a long way.

### Stranding is not purely a function of fullness

The second-worst row in the 80.7% measurement is the *oldest* block group: 52%
full and still stranding 22.5%, worse than block groups 20 points fuller.
Stranding tracks perforation, and perforation accumulates with rewriting, not
just with occupancy. A reclaim policy keyed on fullness alone would miss it.

### What this does not say

These are UML filesystems aged for minutes to hours with a synthetic mixture of
file sizes, deletions and small in-place rewrites. They are not a database, a VM
image store, or a five-year-old array. The workload was chosen to resemble
ordinary use rather than to flatter or punish the design; one built out of small
random overwrites of large files would perforate stripes far harder, and nothing
here measures that. Nor is there a data point above `nr_data = 3`: the bound
above says stranding should grow with the number of data stripes, and a wide
array is the case to measure next.

### The other half of the picture

This measurement is static: how much room the rule costs. The dynamic half is
how often the allocator actually hands out space inside an occupied stripe.
`/sys/fs/btrfs/<uuid>/raid56_write_profile`, added alongside this, counts it --
`sub_stripe_resident_sectors` is committed data that read-modify-writes put at
stake, a number btrfs has never reported. The free-space measurement says what
the rule costs; the write profile says what it buys. Neither is worth much
alone.

## Reproducing

    export BTRFS_TEST_DIR=/var/tmp/btrfs-test
    cd tools/testing/btrfs/uml
    ./age.sh $BTRFS_TEST_DIR/uml-fast/linux r5-80 raid5:raid1 4 2G 0.80
    ./age.sh $BTRFS_TEST_DIR/uml-fast/linux r5-92 raid5:raid1 4 2G 0.92
    ./age.sh $BTRFS_TEST_DIR/uml-fast/linux r6-80 raid6:raid1 4 2G 0.80

Or against an existing array, with no kernel and no privileges:

    btrfs inspect-internal dump-tree -t chunk  /dev/sda > chunk.txt
    btrfs inspect-internal dump-tree -t extent /dev/sda > extent.txt
    tools/testing/btrfs/raid56_row_occupancy.py chunk.txt extent.txt --csv rows.csv
