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
| RAID6 | 4 | 2 | 80.9% full | 908 MiB | **66 MiB (7.3%)** | 0.8% – 20.1% | 53% – 97.0% |
| RAID5 | 4 | 3 | 80.7% full | 1.3 GiB | **227 MiB (17.2%)** | 0.3% – 60.4% | 64% – 99.8% |
| RAID5 | 4 | 3 | 92.5% full | 617 MiB | **294 MiB (47.6%)** | 30.5% – 67.6% | 99.1% – 99.9% |
| RAID5 | 8 | 7 | 80.7% full | 1.4 GiB | **681 MiB (46.1%)** | 26.2% – 100.0% | 99.7% – 100.0% |

Two variables move the answer, and they move it about equally far: how full the
filesystem is kept, and how many data stripes the profile has. A four-disk
RAID5 at 92.5% full and an eight-disk RAID5 at 80.7% full land in the same
place.

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

The eight-disk rows, where it goes wrong:

```
     block group profile nr_data       used       free  used%   stranded stranded% if random
       298844160   RAID5       7  403.3 MiB  313.3 MiB  56.3%  198.5 MiB     63.4%     99.7%
      1050279936   RAID5       7  798.2 MiB   97.8 MiB  89.1%   97.8 MiB    100.0%    100.0%
      1989804032   RAID5       7  749.5 MiB  146.5 MiB  83.7%  110.7 MiB     75.6%    100.0%
      2929328128   RAID5       7  751.0 MiB  145.0 MiB  83.8%  100.0 MiB     69.0%    100.0%
      3868852224   RAID5       7  759.2 MiB  136.8 MiB  84.7%   92.9 MiB     67.9%    100.0%
      4808376320   RAID5       7  690.8 MiB  205.2 MiB  77.1%   53.7 MiB     26.2%    100.0%
      5747900416   RAID5       7   99.2 MiB   17.2 MiB  85.2%    5.7 MiB     33.2%    100.0%
      5869928448   RAID5       5  641.9 MiB  238.1 MiB  72.9%   18.8 MiB      7.9%     99.9%
      6792675328   RAID5       5  161.0 MiB  179.0 MiB  47.3%    3.0 MiB      1.7%     96.0%
```

The block group at 89.1% full strands **100.0%** of its free space: every free
sector in it shares a vertical stripe with a live one. It has reached the
random-placement bound, meaning the allocator's clustering has stopped buying
anything at all.

Both wide filesystems also grew narrower block groups than the profile asks for
-- `nr_data 5` here, `nr_data 1` on the 92.5% filesystem -- because the devices
filled unevenly and btrfs made chunks out of whatever devices still had room.
Narrower chunks strand less by construction, so they flatter the totals
slightly.

## The cost is btrfs's stripe unit, not the rule

Every figure above was measured at one value of a compile-time constant.
`BTRFS_STRIPE_LEN` is `#define SZ_64K` in `fs/btrfs/volumes.h`. A vertical
stripe's `nr_data` members therefore lie 64 KiB apart in logical space, so a
contiguous run of free space must exceed `(nr_data - 1) * 64 KiB` -- 384 KiB on
an eight-disk array -- before it can release even one vertical stripe. The
median data extent in these filesystems is 16 KiB.

Re-gridding the *same extents* onto a finer stripe unit:

| run | 64 KiB | 16 KiB | 8 KiB | 4 KiB |
|---|---|---|---|---|
| RAID6 4-disk, nr_data=2 | 7.3% | 2.4% | 1.3% | 0.6% |
| RAID5 4-disk, nr_data=3 | 17.2% | 5.8% | 3.3% | 1.8% |
| RAID5 4-disk @92% full | 47.6% | 16.7% | 9.3% | 5.2% |
| RAID5 8-disk, nr_data=7 | 46.1% | 18.7% | 11.2% | 6.4% |

The 46% that appeared to kill the immutable-stripe family is a property of the
64 KiB scattered granule, not of the rule. At a 4 KiB granule the worst case in
this whole study is 6.4%.

Three things must travel with that result. The on-disk format already carries
`stripe_len` as a per-chunk `__le64` and mkfs writes it, but the kernel never
reads it back -- `BTRFS_STRIPE_LEN` is a constant everywhere and `tree-checker.c`
enforces it -- so this is an implementation change, not a mount option. A small
stripe unit gives up the property that a small read touches one disk, and
multiplies the number of rbios per byte written. And this models one extent
layout re-gridded, not a filesystem that actually ran at that granule, where the
allocator would have behaved differently.

## What it means

### On a narrow array at ordinary fullness, the rule is affordable

At ~81% full the rule costs 17% of the remaining free space on four-disk RAID5
and 7% on four-disk RAID6 -- 227 MiB of 1.3 GiB, 66 MiB of 908 MiB. Paying it is
equivalent to running the filesystem one to three percentage points fuller than
it really is. That is comfortable.

### On a wide array, or a full one, it is not

The price is steeply non-linear in both variables.

Hold the profile fixed and fill the filesystem from 80.7% to 92.5%, and the tax
goes from 17.2% to 47.6%. Hold the fullness at ~81% and widen the profile from
three data stripes to seven, and it goes from 17.2% to 46.1%. One block group on
the wide array strands *all* of its free space.

This is the opposite of convenient. Wide arrays are exactly where RAID5/6 is
most attractive -- parity overhead falls as the array grows -- so the design is
weakest where it is most wanted. And the mechanism is not subtle: a vertical
stripe of seven sectors is more than twice as likely to contain a live sector as
one of three, at any given occupancy. The random-placement column shows the
ceiling being approached: on every `nr_data 7` block group it is already
99.7-100%.

So an immutable-stripe allocator is not simply viable or not. It is viable on
narrow arrays kept at moderate fullness, and it needs help everywhere else. The
help it needs is to stop allocating in block groups that have climbed the curve,
which is exactly what block-group reclaim exists to make possible: btrfs has
that machinery already
(`/sys/fs/btrfs/<uuid>/allocation/data/bg_reclaim_threshold`) and it is off by
default on non-zoned filesystems. **The feasibility of copy-on-write parity
turns on a knob that already exists**, not on a new on-disk format -- but on a
wide array the threshold would have to be aggressive enough that relocation
traffic becomes its own cost, and nothing here measures that.

### It is affordable because of the allocator, not the geometry

The last column is what the same fullness would strand if live sectors were
scattered at random: a vertical stripe of `nr_data` sectors holds live data with
probability `1 - (1-u)^nr_data`, and every free sector in such a stripe is lost.
That bound runs from 53% to 100% across these filesystems. The measurements run
from 0.3% to 100%.

Almost all of the free space an immutable-stripe allocator would keep is free
only because `find_free_extent()` already packs live data into clusters instead
of spreading it. The design is not standing on the geometry of RAID5/6; it is
standing on btrfs's allocation policy. Worth writing down, because an allocator
change made for unrelated reasons could move this number a long way.

The wide array shows the other end of that: on a seven-data-stripe block group
at 89% full, the measurement *equals* the random bound. Clustering had stopped
helping entirely. Whatever margin this design has, it comes from the allocator,
and on wide arrays the allocator runs out of margin to give.

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
here measures that. Nor is there a data point above `nr_data = 7`,
or on an array wide enough (twelve, sixteen disks) to be interesting for the
profiles where the write hole is most often argued about.

### The other half of the picture

This measurement is static: how much room the rule costs. The dynamic half is
how often the allocator actually hands out space inside an occupied stripe.
`/sys/fs/btrfs/<uuid>/raid56_write_profile`, added alongside this, counts it --
`sub_stripe_resident_sectors` is committed data that read-modify-writes put at
stake, a number btrfs has never reported.

The eight-disk aging run, which wrote 12 GiB, reported:

```
full_stripe_writes 19435          inplace_full_stripe_writes 0
sub_stripe_writes 39170           sub_stripe_vertical_stripes 400808
sub_stripe_written_sectors 1064830
sub_stripe_resident_sectors 1680992
```

Two thirds of the RAID5 writes this workload issued were sub-stripe writes, and
they disturbed vertical stripes holding at most 1.68 million sectors -- 6.4 GiB
-- besides the 1.06 million they wrote themselves.

That is an upper bound, not a measurement. `rmw_assemble_write_bios()` marks a
sector resident purely because the write did not supply it, and raid56.c cannot
tell a committed sector from a free one, so
`written + resident == vstripes * nr_data` is an identity. Checking the aged
images against the extent tree offline puts the genuinely allocated share of
those resident sectors at 86% on the eight-disk array and 91-94% on the others.
So the real figure is close to the bound -- about 1.33 sectors of committed data
exposed per sector written at nr_data=7 -- but the counter alone does not
establish it.

The free-space measurement says what the immutable-stripe rule costs; the write
profile says what it buys. Neither is worth much alone.

## What the write-intent log actually costs

The log is the other half of the comparison, and its cost was asserted rather
than measured. Its *space* cost genuinely is fixed and width-independent: 8 KiB
per device at a fixed offset, inside the 1 MiB btrfs already reserves. Its *IO*
cost is neither.

`btrfs_wib_mark()` records a stripe before the RMW submits anything, and
`wib_write_block_locked()` skips the device writes when the block it builds is
byte-identical to the last one that reached every device. How often that fires
decides the cost, so the eight-disk aging run was repeated with the log's own
counters captured:

```
marks 38879   commits 29287   commit_flushes 34   commit_errors 0
sub_stripe_writes 38879
```

- Marks track sub-stripe writes exactly 1:1, as designed.
- 75.3% of them still forced an all-device round trip; the dedup saves 24.7%.
- That is 234,296 FUA writes of 4 KiB -- 915 MiB -- against 5765 MiB of RMW
  data and parity, so **15.9% of the read-modify-write traffic** and 7.6% of the
  12 GiB the workload wrote in total.
- Per sub-stripe write: 24 KiB of log for 152 KiB of payload.

The cost is O(devices) per commit, so it grows with array width -- the opposite
of the space cost. The same workload on four disks would pay about half.

That is a real number to weigh against stranding, and it is not negligible.
It also identifies the optimisation worth doing first: Ceph never cleans up its
rollback state synchronously, it piggybacks the cleanup on the following write.
The 24.7% the byte-identical check already saves suggests how much more
deferring or batching the clears could recover.

## Reproducing

    export BTRFS_TEST_DIR=/var/tmp/btrfs-test
    cd tools/testing/btrfs/uml
    ./age.sh $BTRFS_TEST_DIR/uml-fast/linux r5-80 raid5:raid1 4 2G 0.80
    ./age.sh $BTRFS_TEST_DIR/uml-fast/linux r5-92 raid5:raid1 4 2G 0.92
    ./age.sh $BTRFS_TEST_DIR/uml-fast/linux r6-80 raid6:raid1 4 2G 0.80
    ./age.sh $BTRFS_TEST_DIR/uml-fast/linux w8-80 raid5:raid1 8 1G 0.80

Or against an existing array, with no kernel and no privileges:

    btrfs inspect-internal dump-tree -t chunk  /dev/sda > chunk.txt
    btrfs inspect-internal dump-tree -t extent /dev/sda > extent.txt
    tools/testing/btrfs/raid56_row_occupancy.py chunk.txt extent.txt --csv rows.csv
