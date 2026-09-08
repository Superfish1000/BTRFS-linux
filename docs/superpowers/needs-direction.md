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

## 6. RAID6 Q cross-check: tested, did not reproduce

**The claim.** `recover_verify_q()` rejects a rebuild whenever the two parity
blocks disagree, and they legitimately disagree on stripes holding no committed
data -- so a degraded RAID6 array could not write into fresh space at all.

**Tested.** `uml/degraded_fresh.sh` boots an array degraded from the first
mount and writes into never-written space. On six devices with one omitted,
where the chunk is wide enough for sub-stripe writes to exist at all
(`sub_stripe_writes 23`), all 21 writes plus an in-place nodatacow overwrite
succeeded, with no Q-syndrome warning.

**Why not.** The premise does not hold on these images: unwritten space is
zeros, so P and Q are both zero and agree trivially. The check needs unwritten
space holding *garbage* -- a disk reused from something else -- before P and Q
disagree there.

**What is left.** A narrower question than the original: whether a reused disk
with non-zero content in never-written regions can make a degraded RAID6 refuse
sub-stripe writes. Reproducing it means seeding the images with garbage before
mkfs, which the rig does not currently do. Recorded rather than closed, because
"did not reproduce under the conditions I tried" is not "cannot happen".

Note the first attempt at this test passed while proving nothing: on four
devices with one omitted the chunk is three wide, `nr_data` is 1, and no write
can be sub-stripe -- `sub_stripe_writes` stayed 0. The write profile counters
are what caught that.

---

## 4. Two residual exposures the model checker still reports

Both reproduce in `tools/testing/btrfs/raid56_redundancy_model.py`; the sweep
runs them under their own heading and `regress.sh` diffs the result against
`tools/testing/btrfs/uml/residual-exposures.txt`. Both are documented rather
than fixed, because both need a semantic decision about what a failed sector
write should mean.

**`--in-place --strict`:** a `nodatacow` or prealloc write overwrites
referenced sectors by definition, so committed data is at risk even when the
write covers the full stripe. The log records these (`RBIO_INPLACE_BIT`) so
parity is recoverable, but the overwritten data itself is not. It only shows
under `--strict`, which is the mode that asks whether a *failed* write may
destroy committed data; outside it a failed write is allowed to, so an
`--in-place` row without `--strict` cannot violate and checking one proves
nothing. Reported at both parities and both depths.

**`--nodatasum`:** without checksums a stale sector cannot be told from a good
one, so a reconstruction from a parity that a failed write left behind is
returned as if it were correct. Reported for **RAID6 only**:

```
history: ('rmw',(1,),('1','p0','p1')) ; ('rmw',(1,),('p0','p1')) ; ('rmw',(1,),('p1',))
final:   disk=[0,102] parity=[(0,102),(0,1)] committed=[0,102]
```

The last write lands its data and p0 but not p1, so one fault against a
two-parity profile and the write is accepted. Its true margin is one, and the
de-rate charges exactly that -- so `len(faults) <= budget` holds. Lose the data
device and p0 and the only equation left is the stale p1, which reconstructs
the pre-write value. With checksums that is a detected unreadable sector and
the stripe is recorded for repair; without them it is returned as data.

RAID5 does not show it: a single parity that fails a write leaves a margin of
zero, so the write is not accepted in the first place.

**The choice.** Whether a write that spends redundancy should be refused
outright on a `nodatasum` filesystem -- which means any transient write error
on any one device fails the whole write, on the profile that is supposed to
absorb it -- or continue to be accepted with the exposure documented. The
write-intent log narrows the window (the stripe is recorded and the next scrub
repairs it) but does not close it: devices that die before that scrub runs are
enough.

---
