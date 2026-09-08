# What has been audited, and what was found

Absence of findings only means something if you know what was looked at. This
records the checks made over the RAID5/6 integrity series, so a later reader can
tell a clean area from an unexamined one.

Fixes are in git history; questions needing a decision are in
`needs-direction.md`.

## Verified clean

**Alignment arithmetic.** The full stripe length is `nr_data * 64 KiB` and is not
a power of two, so `IS_ALIGNED`/`round_*` on it are bugs -- a class that already
bit once here. Every alignment operation in `raid56-wib.c`, `raid56.c` and
`scrub.c` was checked: `BTRFS_WIB_BLOCK_SIZE` is `1ULL << 16`; the sole
full-stripe alignment is `IS_ALIGNED(offset_in_full_stripe, BTRFS_STRIPE_LEN)`,
which aligns an offset *within* a stripe to 64 KiB rather than to the full
length, and is correct. No further instances.

**Spinlock regions.** Every `spin_lock(&...)` region in `raid56-wib.c` was
scanned for allocations, mutexes, bio submission, and waits. None contains a
sleeping or blocking call.

**Allocation and free pairing.** Every allocation in the log reaches its free on
all paths, including both early returns in `wib_submit_all_devices()`.
`get_file()`/`fput()` pair across the retry loop and the exit path.
`bio_alloc()` is called with `GFP_NOFS`/`GFP_KERNEL`, which cannot fail from a
bioset, so the absent NULL checks are correct rather than oversights.

**Return-value contracts.** `wib_recover_one()` returns 0 (drop the record), 1
(keep it recorded) or a negative error. Both callers -- `btrfs_wib_recover()`
and `btrfs_wib_recover_after_replay()` -- handle all three.

**Hostile on-disk data.** Both `wib_read_slot()` callers validate through
`btrfs_wib_block_valid()` before use; `nr_entries` is bounds checked before
indexing; the checksum covers the whole block. Two gaps found here were fixed
(unknown format fields accepted, unbounded count in the union path) and are
covered by self tests.

**The two-pass retry in `rmw_retry_failed_sectors()`.** Correctness depends on
pass 2 clearing exactly what pass 1 queued -- an asymmetry would lose a fault
and let a write be accepted below the profile's redundancy, which is the bug
this function exists to fix. The skip conditions were compared line by line and
match on all three (`!dev->bdev`, `!test_bit`, data sector with no paddrs).
Pass 1's early `return false` runs before pass 2, so an abandoned retry clears
nothing, and no bio is submitted between the passes so `error_bitmap` cannot
change under them.

**Fault accounting completeness.** All six tolerance checks in `raid56.c` use
`rbio_max_errors()`; none still compares against the raw `bioc->max_errors`,
which `volumes.c:6991` inflates by the replace target.

**The model matches the code.** `raid56_redundancy_model.py` tolerates
`nr_parity` faults; the kernel's `rbio_max_errors()` is `real_stripes - nr_data`,
the same quantity. Its `replace_inflation` policy flag reproduces the
`handle_ops_on_dev_replace()` behaviour the fix guards against, which is what
lets the sweep prove that reverting the fix breaks something.

## How the testing is kept honest

`tools/testing/btrfs/uml/regress.sh` judges its own output and exits non-zero.
It fails if the two documented residual exposures *stop* violating -- that would
mean the model changed rather than the code improving -- and if any reverted
accounting fix stops breaking something, which is what keeps those fixes proven
load-bearing.

`regress.sh --self-check` doctors a real sweep two ways and confirms the
checking logic flags both, so the suite demonstrates it can fail rather than
only ever reporting that it did not.

Kernel fixes are additionally verified by negative control: remove the fix,
confirm the new test reports the failure, restore it, confirm a clean run.

## Acknowledged loss at three or more data stripes -- closed

Logged as an open question while the sweep only ever ran at `--data 2`. The
choice it posed -- whether an RMW should de-rate its fault tolerance when the
stripe it is about to write is already one fault down -- was taken: the model's
`sticky_derate` policy computes the stripe's true remaining margin (the parities
that still agree with the disk on every non-stale sector, minus the sectors that
need them) and caps the fault budget with it.

`sweep.sh` now runs `--data 3`, `--data 4` and `--data 5` at both parities and
all six are clean. Reverting the de-rate (`--no-sticky-derate`) reintroduces
acknowledged loss at `--data 3` and `--data 4`, which is what keeps the check
from passing vacuously.

An earlier form of the de-rate counted stale sectors *and* stale parities,
charging two equations for one lost one. It over-derated enough to mask the
`missing_faults` bug: reverting that fix stopped breaking anything, so the check
meant to prove it load-bearing was passing for the wrong reason.

## The residual-exposure check was checking nothing

`regress.sh` asserted that every `--in-place` and `--nodatasum` row of the sweep
violates. Four of the eight were `--in-place` rows run without `--strict`, and
in that mode a failed write is *allowed* to destroy the data it overwrote -- so
those rows can never violate and the assertion could only fail. The sweep now
runs `--in-place` with `--strict`, and the check diffs against a recorded
baseline instead, so a row moving in either direction is surfaced: a new
exposure, or one that closed and should come out of the docs.
