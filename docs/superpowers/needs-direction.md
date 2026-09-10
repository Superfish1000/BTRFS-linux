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

**What.** `sweep.sh` originally never passed `--data`, so every configuration
behind the "fixed accounting is clean everywhere" claim ran at the default of
two data stripes -- a 3-disk RAID5 and a 4-disk RAID6. The arrays actually
measured in this series have `nr_data` 3 and 7. At three or more the model
reports acknowledged loss, for both RAID5 and RAID6:

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

**The choice.** Whether an RMW should de-rate its fault tolerance when the
stripe it is about to write is already one fault down -- at the cost of failing
writes that today succeed. Or whether this is inherent to a one-fault-tolerant
profile taking two faults, and belongs in the documented exposures instead.

### Both de-rate variants were built and measured

Written, run, and then backed out. `sweep.sh` runs both so the numbers stay
visible.

**Flat (`--flat-sticky-derate`).** `btrfs_wib_has_sticky()` before the writes,
then `rbio_max_errors(rbio) - degraded` after them. Implementable: it needs
only the log's sticky bit. It **does** close the wider-array loss at `--data 3`
and `--data 4`, for both parities.

It also breaks degraded arrays. The sticky bit does not say why it was set, and
a missing device sets one on every write it touches -- but that same fault is
already counted against the next write by the `missing_faults` rule, so
de-rating for it charges one lost equation twice. On a RAID5 with a device
gone that is the entire budget: the first write to a full stripe succeeds and
records it, and every write to that stripe afterwards returns EIO. A degraded
array goes read-only one stripe at a time.

Suppressing the de-rate while any device is missing fixes that particular case
and leaves the real cost: on a healthy array, a stripe that took one transient
write error refuses its next failing write until a scrub clears the record.
That is correct for integrity and is a loss of availability, which is the
trade-off this entry exists to have decided.

**Counted (`--counted-sticky-derate`).** Caps the budget by the stripe's true
remaining margin -- the parities still agreeing with the disk on every
non-stale sector, minus the sectors needing them. Strictly stronger, and *not*
implementable the same way: computing it needs every parity compared against
every sector on disk, which the write path does not have and cannot afford to
read. It is in the model to show what the extra strength would buy, not as a
candidate.

**The trap this walked into.** For a while the model's default policy was the
counted de-rate while the kernel had neither, so the sweep reported "wider
arrays clean" and this entry was deleted as resolved. Nothing in the kernel had
changed. The model's default is now the kernel's behaviour -- no de-rate -- and
a variant has to be asked for by name.

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
returned as if it were correct. Reported at both parities:

```
history: ('rmw', (1,), ('1', 'p0')) ; ('rmw', (1,), ('p0',))
final:   disk=[0, 101] parity=[(0, 1)] committed=[0, 101]
         read of stripe 1 after losing device 1 returns 1, not 101
```

The second write lands 101 on the data device and loses only its parity write:
one fault, inside the profile's tolerance, so it is accepted. The parity is now
stale -- it still describes the pre-write value. Lose the data device and the
reconstruction from that parity returns 1. With checksums that is a detected
mismatch and the read fails; without them it is returned as data, and the
acknowledged write is silently undone.

**The choice.** Whether a write that spends redundancy should be refused
outright on a `nodatasum` filesystem -- which means any transient write error
on any one device fails the whole write, on the profile that is supposed to
absorb it -- or continue to be accepted with the exposure documented. The
write-intent log narrows the window (the stripe is recorded and the next scrub
repairs it) but does not close it: devices that die before that scrub runs are
enough.

---

---

## 7. Persisting the stale record costs log capacity

**What.** The scrub fix works off the log's `stale` record -- which data column
holds content a failed write left on disk. That record lives only in memory, so
across a mount only `sticky` survives, and `sticky` says a write failed without
saying which side of the stripe is wrong. Until it is persisted, the scrub
protection is per-mount only: the first `btrfs scrub` after a reboot can still
destroy the parity copy.

**The change.** `struct btrfs_wib_disk_entry` grows from 24 to 32 bytes: one
more `__le64` carrying `stale`, with parity staleness packed into the same
bitmap (the block at the full stripe's start encodes parity 0, the next block
parity 1 -- `nr_data` is at least 2, so those bits always belong to the stripe
they describe).

**The cost, measured -- and it is not the one this entry originally named.**
The obvious reading is "less dirty address space tracked", which sounds
harmless. The real cost is on the write path.

The on-disk block is not the in-flight set: `btrfs_wib_build_block()` unions
the live table with `wib->last`, so the block is the running union of every
region marked since the last drop, and drops happen only at transaction commit
(30s by default). When that union no longer fits, `wib_write_block_locked()`
returns `-ENOSPC` and `wib_commit_locked()` falls back to
`wib_flush_and_drop_locked()` -- a `REQ_PREFLUSH` to **every writable device**
plus a FUA block write, up to three times, **with the marking RMW blocked on
it** inside `btrfs_wib_mark()`.

That overflow fires once per `BTRFS_WIB_MAX_ENTRIES` distinct new 4MiB
regions. So the entry size sets the rate of inline device-wide cache flushes
on the write path:

| entry | entries/slot | tracked | flush rate |
|---|---|---|---|
| 24B, today (no stale) | 165 | 660 MiB | 1.00x |
| 32B (+stale) | 124 | 496 MiB | 1.33x |
| 40B (+stale, +stale_par) -- **what is implemented** | 99 | 396 MiB | 1.67x |

The in-memory table is a fixed array sized by the same constant
(`entries[BTRFS_WIB_MAX_ENTRIES]`), so it cannot be tuned independently. More
slots do not help: the two slots are alternating generations of the same
block. A bigger slot has 512KiB of physical headroom but is blocked by
single-page buffers and single-page bios.

**The remedy, designed but not built.** `stale` is zero almost always -- the
design says so itself, which is why `btrfs_wib_stale()` has a lock-free
`nr_stale == 0` fast path. So encode it out of the common case: keep the
24-byte entry, and append a sparse extension array of `{__le32 index, __le64
stale, __le64 stale_par}` (20 bytes) after it, with the count in the header.
With no stale records that is 165 entries and **no regression at all**; with
every entry stale it is 90, slightly worse than the flat 99, which is the
right way round -- the pathological case pays and the normal case does not.

**The choice.** Ship the flat 40-byte entry and its 1.67x flush rate; or build
the sparse encoding first; or leave the record per-mount and accept that the
protection resets at every boot -- which the model prices at 1488 of 8386
RAID5 states destroyed, i.e. the whole fix.

---

## 8. Scrub: skip the stripe, or rebuild it

**What.** `scrub_raid56_parity_stripe()` now declines to regenerate the parity
when the log records a data column of that full stripe stale. Sound, and small:
one early return. The state-machine model scores it 0 on every axis.

But it does not repair. The stronger policy -- rebuild the stale column *from*
the parity, write it back, then regenerate -- is also clean and leaves far
fewer stripes without redundancy: 259 against 973 on RAID5, 2718 against 9705
on RAID6.

**Why it is not done.** It needs a write-back path scrub does not have at that
point. The machinery exists: marking the stale sectors in the scrub stripe's
error bitmap after `scrub_verify_one_stripe()` would make the existing repair
loop reconstruct them through mirror 2 and write them back. It has to go in
`scrub_stripe_read_repair_worker()`, which only knows its own data column, so
it needs a chunk-map lookup to find the full stripe.

**The choice.** Ship the skip and leave 3.5x more stripes unrepaired, or build
the write-back path.

---

## 9. Debug knobs that turn protections off

**What.** Two `CONFIG_BTRFS_DEBUG`-only module parameters were added:

- `raid56_allow_nodatacow` -- turns off both the `chattr +C` refusal and the
  forced copy-on-write fallback.
- `raid56_stale_read_legacy` -- restores the read-path behaviour that ignores
  the rebuild budget.

Both exist because the reproductions cannot otherwise reach the states they
demonstrate: refusing `chattr +C` removes the only way to *build* the
nodatacow-on-RAID5/6 state, and a negative control needs the defect back.

**The choice.** Whether shipping switches that restore known defects, even in
debug builds, is acceptable. The alternative is a second kernel build per
control, which is what made negative controls expensive enough to skip -- and
skipping them is how five claims got made and withdrawn in this series.

---

## 10. `chattr +C` on RAID5/6 now fails

**What.** `check_fsflags_compatible()` returns `-EPERM` for `FS_NOCOW_FL` when
the RAID56 incompat bit is set, matching the existing zoned precedent. Anything
that scripts `chattr +C` on a RAID5/6 array -- VM image directories, database
data directories, `systemd-nspawn` machine trees -- starts failing.

**The choice.** Refusal, which is what the zoned case does and what the user
asked for over silently substituting different behaviour; or a warning plus the
forced copy-on-write, which keeps those scripts working while quietly changing
what they get.

---

## 11. A crash on a failing device leaves files reading back complete and wrong

**What.** The `flakey` scenario -- background writers, one device failing
every write, then a crash, then probes with one device omitted -- reports two
classes of damaged file, and `regress.sh` now separates them:

- **read failed** (4 to 19 per run): the read errors and `md5sum` prints
  nothing. This is item 1 of this document: the log records stripe addresses,
  not content, so a stripe whose data is gone cannot be rebuilt, and the
  kernel says so.
- **wrong data** (0 to 5 per run): the read SUCCEEDS and returns a file of
  exactly the right length whose content differs from what was fsync'd. No
  checksum error is raised.

**Why the second one should not be possible.** The writers use plain `dd`, so
the data is checksummed. Metadata is `raid1`, so the checksum tree is not
touched by the RAID5 degradation. Each file is created exactly once, so there
is no earlier version to roll back to. On those three facts a wrong
reconstruction has to fail its checksum and the read has to error. It does
not, so one of the three is false, and which one is not yet established.

Every mismatching file measured is at exactly its expected size --
45056/45056, 57344/57344, 28672/28672, 53248/53248, 61440/61440, 32768/32768
-- so it is not truncation, which was the obvious explanation and is dead.

**Not this series.** It reproduces with `noraid56_write_intent`, and more
often, not less:

| | wrong data | read failed |
|---|---|---|
| log on | 1, 1, 2, 3, 3 | 0, 5, 7, 9, 11 |
| log off | 0, 3, 5, 7 | 4, 6, 11, 19 |

An earlier reading called the log implicated, on the strength of one run per
arm that happened to give 3 against 0. Repeating the log-off arm gave 3, 5 and
7, so that was noise -- and the fuller picture points the other way. It also
predates every commit in this night's work.

**Reproduce.** `BTRFS_TEST_DIR=... tools/testing/btrfs/uml/dmfail34.sh
<kernel> <tag> flakey raid5:raid1 rw 4 2`

**The choice.** Whether to chase this now -- it is an upstream-shaped bug in
the crash path rather than part of the write-hole work -- or record it and
carry on with the series.

