# Repair what can be proved, preserve what cannot, never guess

The write-intent log's scrub side used to decline to regenerate the parity of
any stripe carrying a stale record. Sound -- it never destroyed data -- but
blunt in three ways, and the third was permanent.

## What the record can and cannot prove

Three per-block records, and the difference between them is the whole design:

| record | means | proves |
|---|---|---|
| `bitmap` | a write was in flight when the log was last written | a crash happened mid-write |
| `sticky` | a write touching this block went wrong | **nothing about which member** |
| `stale` | this data column's own write failed, in a write that supplied it | **names the member**: the acknowledged value is in the parity |
| `stale_par` | this parity does not describe the data on disk | names a parity as unusable |

`stale` is a strict subset of `sticky`, so `sticky & ~stale` is exactly
"something happened here and nothing can say what".

## The decision

Per full stripe, in `scrub_raid56_parity_stripe()`:

**Content that carries its own proof is never blocked.** A sector with a data
checksum, or a metadata sector with its own header and generation, is verified
and repaired by the ordinary scrub path. Since `chattr +C` is refused on
RAID5/6, that is most of what the record covers in practice -- the previous
blunt skip was declining repairs scrub was perfectly capable of.

**Named members within the budget are repaired.** When the columns that cannot
be believed -- `stale`, plus any on a missing device -- are no more numerous
than the parities still usable, the sectors are marked after
`scrub_verify_one_stripe()`, the existing mirror loop rebuilds them from the
parity, `scrub_write_sectors()` writes them back, the parity is regenerated,
and **the record is retired**.

**Everything else is left exactly as it was found.** Rebuilding would invent a
value nothing committed; regenerating the parity would destroy the last copy of
one that was. Neither happens. The record stays, and the ioctl below hands it
to a helper that can involve a human.

## Why retirement matters more than it looks

Nothing else retires a record. `stale ⊆ sticky` makes
`trusted = !wib_pending_has_error()` always false for a recorded stripe;
`wib_recover_one()` with `trusted == false` returns 1 unconditionally, which is
the re-arm branch; `btrfs_wib_recover_after_replay()` passes `false` literally,
so its `clear_sticky()` is dead code for any live stripe. So before this, a
stripe that took one transient write error kept its degraded redundancy
**for good**. The repair is what ends that.

Measured: `sticky_blocks 33 -> 0` across one scrub, `scrub_skipped_stale 0`,
three `rebuilding N sector(s) from the parity` messages. The test asserts the
retirement, so a regression back to skipping fails it.

## A refinement that was tried and backed out

`rmw_rbio()` records the outcome of a write whether or not the write was
acknowledged. That looks wrong: a refused write acknowledged nothing, so naming
a column stale there seems to claim proof we do not have. It is the wrong
layer, and the model says so -- `--policy prove-or-preserve
--only-claim-on-acked`:

| | MISREPAIR | DESTROY |
|---|---|---|
| record what the devices did (the kernel) | 0 | 0 |
| record only acknowledged writes | 480 | 297 |

The fields state what the **devices** did; whether that amounts to proof is
judged later, by the budget. A refused write whose parity landed leaves that
parity describing a vector nobody committed, and unless the record says so the
budget believes it is a usable source and rebuilds live data out of it. The
clearing half matters as much: skipping it leaves a stale mark on the one
column that is now right.

## The preserved half

`BTRFS_IOC_RAID56_STALE_STRIPES` exports the records uninterpreted, so a helper
can map a region to files with `BTRFS_IOC_LOGICAL_INO` and compute both
candidate values from the devices itself, without writing anything until a
human or a format-aware check has chosen.

Almost everything such a helper needs can be recovered later by reading the
disks: the geometry and column-to-device mapping from the chunk tree, the file
behind an address, and both candidates for a named column. **One thing cannot**,
so the record carries it: a **generation**. A logical address is reused once its
extent is freed and reallocated, and without knowing when the damage was
recorded a helper cannot tell whether the extent it finds there now is the one
that was damaged. Pointing a human at the wrong file is worse than pointing them
at none. It is an upper bound over the region, so the test stays conservative:
an extent newer than the record was written after it and the record does not
describe it.

`tools/testing/btrfs/wibdump.c` is the reference reader. It withholds its
per-stripe verdict unless given the block group start, because full stripes tile
from the block group while log regions are 4MiB-aligned -- grouping columns by
the wrong grid would be exactly the kind of guess this interface exists to
avoid. An earlier version did that and reported two AMBIGUOUS stripes the kernel
had in fact repaired.

## Four defects the adversarial review found in the above

Every one of them was in code that had already been written, built clean,
passed the self tests, and passed the UML scenarios with a working negative
control. None of them would have been found by running more tests.

**The clearing side was coarse where it asserts health.** One log bit covers a
whole 64KiB column, but a sub-stripe write touches only the vertical stripes it
was given. `rmw_update_stale_data()` cleared the bit whenever the rbio supplied
*any* sector of the column, so a single landed 4KiB write turned off a record
describing fifteen sectors it never went near -- one of which held the only copy
of an acknowledged value, in the parity. Marking coarsely is conservative;
clearing coarsely loses data. It now clears only when the write supplied the
entire column. `btrfs_wib_done()` already refuses to clear for exactly this
reason one level up, where the range is the full stripe and the unit is the
column; the same argument one level down was not applied.

**There were two budgets, and the stricter one failed silently.**
`scrub_raid56_plan_wib()` counted a stale column as a hole only if it held
unverifiable extent sectors; `mark_stale_sectors()` counts every stale column
and every bad parity. So scrub could authorise a rebuild that the recovery path
then declined -- and declining there means *returning without marking*, so the
column the log names is read off the disk and believed. On an ordinary read that
is no worse than not having the record. On the repair path the result is written
back. The two are now one question: a reconstruction is determined by columns
and parities, not by which sectors carry their own proof, so `holes` counts
every named column and `needs_help` separately decides whether it is our
business at all.

**Retirement was gated on `!sctx->readonly` and nothing else.** A failed repair
write lands in `stripe->write_error_bitmap`, which is not one of the scrub
bitmaps and which the unrepaired-sectors check never reads -- the reconstruction
cleared those bits by succeeding *in memory*. And the parity written afterwards
is computed from that same memory, so it describes the repaired value whether or
not the disk received it. The record was being retired on the strength of a
repair that had not happened, forgetting the stripe most in need of another
look. `btrfs_scrub_raid56_full_stripe()` already folds that bitmap into its
result for the recovery caller; the check simply was not on the user scrub's
path. It is now.

**The ambiguous case was partly manufactured.** `logged` is false for a
full-stripe non-in-place write, so the tail took a branch that recorded only
"something went wrong in this stripe" -- while `rbio->error_bitmap`, right
there, named the column and the sectors. That turned something known into
something unknown, and a stripe the log cannot name is one the repair path must
decline. It mattered most for the data that could least afford it: NODATACOW is
forced to copy-on-write on RAID5/6, so *every* checksumless write there is a
full-stripe COW write and took that branch. The one class with no checksum to
appeal to was the one class that could never get a column name.

**Not modelled.** The first of these is about sub-column granularity, and the
state machine treats a column as atomic. It is argued in the code and against
the precedent one level up, not measured. That is a weaker standard than the
rest of this work is held to.
