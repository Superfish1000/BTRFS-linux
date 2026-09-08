# Open questions that need a decision

Things found while working on the RAID5/6 integrity series that are **not**
safe to fix autonomously, because the code is not simply wrong -- there is a
trade-off, a design choice, or a user-visible change involved. Each entry says
what was found, what the choice is, and what it would cost.

Bugs with an unambiguous correct fix are not listed here; those are fixed and
committed directly.

---

## 1. Crash + device loss is still unrecoverable

**What.** The write-intent log records stripe *addresses*, not data. Recovery
recomputes parity from the sectors on disk, which works because after a crash
the data is intact and only parity is stale. If a device dies before recovery
runs, there is no longer enough data to recompute, and the stripe is lost.

**The choice.** Closing it means journalling content, as Linux MD's RAID5
journal does. Measured against the eight-disk aging run: the log currently
writes 234K sectors; journalling the data and parity of every sub-stripe write
would write 1,476K. **Write amplification goes from 16% of RMW traffic to
100%.** MD makes its journal optional for exactly this reason.

**Options.** (a) Leave as is and document the limit. (b) Add optional
journalling behind a mount option or feature flag. (c) Journal only parity,
which is cheaper but does not close the gap on its own.

---

## 2. BTRFS_STRIPE_LEN is a compile-time constant

**What.** Stranded free space under an immutable-stripe rule is dominated by
the 64 KiB stripe unit, not by the rule. Re-gridding the same aged filesystems:

| | 64 KiB | 16 KiB | 8 KiB | 4 KiB |
|---|---|---|---|---|
| RAID5 8-disk, nr_data=7 | 46.1% | 18.7% | 11.2% | 6.4% |
| RAID5 4-disk @92% full | 47.6% | 16.7% | 9.3% | 5.2% |

The on-disk format already carries `stripe_len` as a per-chunk `__le64` and
mkfs writes it, but `BTRFS_STRIPE_LEN` is `#define SZ_64K` in `volumes.h`, the
kernel never reads the field back, and `tree-checker.c` enforces the constant.

**The choice.** Making it variable is a substantial kernel change and costs the
property that a small read touches a single disk, plus many more rbios per
byte written. Worth it only if the immutable-stripe family is being pursued.

**Cheap next step if wanted.** Rebuild the UML kernel with a smaller
`BTRFS_STRIPE_LEN` and re-run the aging workload, to check the modelled numbers
against a filesystem that actually ran at that granule.

---

## 3. Stripe alignment is silently dropped on the bitmap path (pre-existing)

**What.** `bg->full_stripe_len` is cached at `block-group.c:2421` and passed as
an alignment into `find_free_space()` (`free-space-cache.c:3104`). On the
extent path it is honoured. On the **bitmap** path it is not:
`search_bitmap()` takes no alignment argument, and `find_free_space()` uses the
aligned offset only as a search start, returning whatever
`*offset = i * unit + bitmap_info->offset` finds
(`free-space-cache.c:2079-2087`).

So once a block group's free space has degraded into bitmaps -- which is what
happens as a filesystem ages, exactly when it matters -- stripe-aligned
allocation stops happening, with no indication.

Separately, alignment is applied only `if (*bytes >= align)`
(`free-space-cache.c:2056`), so it never applies to requests smaller than a
full stripe. That one looks deliberate: aligning a 4 KiB request to 448 KiB
would waste the difference.

**Why this is not fixed here.** It is upstream code, not part of this series;
the effect is on performance (more read-modify-writes) rather than correctness;
and honouring alignment inside bitmaps changes allocation behaviour for every
profile, not just RAID5/6.

**The choice.** Leave it; or teach `search_bitmap()` an alignment and measure
the effect on the full-stripe versus sub-stripe ratio, which
`/sys/fs/btrfs/<uuid>/raid56_write_profile` now reports directly.

---

## 5. The model reports acknowledged loss at three or more data stripes

**What.** `sweep.sh` never passed `--data`, so every configuration behind the
"fixed accounting is clean everywhere" claim ran at the default of two data
stripes -- a 3-disk RAID5 and a 4-disk RAID6. The arrays actually measured in
this series have `nr_data` 3 and 7. At three or more the model reports
acknowledged loss, for both RAID5 and RAID6:

```
history: ('rmw', (1,2), ('1','2','p0')) ; ('rmw', (2,), ('2',)) ; ('rmw', (1,), ('p0',))
final:   disk=[0,102,2]  parity=[(0,1,101)]  committed=[0,102,101]
```

The second write puts 101 into stripe 2; its data write fails and only the
parity carries the value. One fault against one parity, so the write is
accepted. The third write touches stripe 1 and loses its parity write. Again
one fault, again accepted -- but parity was the only copy of stripe 2, so that
stripe's committed content now exists nowhere.

`nr_data = 2` is clean at depth 5, so this is a width property and not a
search-depth artifact.

**Why it is not obviously a defect.** Each RMW counts faults within its own
rbio, which is what `rbio_max_errors()` is for; neither write individually
exceeds the profile. The stripe is left recorded as sticky in the write-intent
log precisely because it completed with a device error, so the next mount
scrubs it and restores redundancy. The exposure is the window between the
failed write and that scrub.

**The choice.** Whether an RMW should consult the log's sticky state for the
stripe it is about to write and refuse, or de-rate its fault tolerance, when the
stripe is already one fault down -- at the cost of failing writes that today
succeed. Or whether this is inherent to a one-fault-tolerant profile taking two
faults, and belongs in the documented exposures instead.

**What was done meanwhile.** `sweep.sh` now runs `--data 3` and `--data 4` under
a separate heading, and `regress.sh` reports the result rather than omitting it,
so the finding is visible in every run instead of being invisible by
construction.

---

## 4. Two residual exposures the model checker still reports

Both reproduce in `tools/testing/btrfs/raid56_redundancy_model.py` and are
documented rather than fixed, because both need a semantic decision about what
a failed sector write should mean.

**`--nodatasum`:** for data without checksums, a sector write that is accepted
but fails leaves reads returning the pre-write content silently. Combined with
a later parity failure that is two faults, and the data is gone.

**`--in-place`:** a `nodatacow` or prealloc write overwrites referenced sectors
by definition, so committed data is at risk even when the write covers the full
stripe. The log records these (`RBIO_INPLACE_BIT`) so parity is recoverable,
but the overwritten data itself is not.

**The choice.** Whether either should fail the write, return an error to the
caller, or continue to be accepted with the exposure documented.

---
