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

## A model whose default policy was not the kernel's

Logged as closed, wrongly, and then reopened. Worth keeping because of how it
happened rather than what it was.

The model gained a `sticky_derate` policy that caps a write's fault budget by
what the stripe has left, and it was made the *default* of the "fixed" policy.
The sweep then reported the wider-array configurations clean, the regression
suite reported "wider arrays now clean -- update needs-direction.md", and the
entry was deleted as resolved.

Nothing in the kernel had changed. `rbio_max_errors()` is
`real_stripes - nr_data` -- the flat profile tolerance -- and no caller
consults the write-intent log before a write. The model was validating a policy
that existed only in the model, and every check built on it agreed, because
they all measured the model against itself.

Caught by asking a question the checks could not: which line of the kernel
implements the policy the model says is load-bearing? There was none.

Two things came out of it. The model's default is now the kernel's behaviour,
so a proposal has to be asked for by name (`--flat-sticky-derate`,
`--counted-sticky-derate`), and both are run by `sweep.sh` under a heading that
says they are not implemented. And the de-rate was then implemented and backed
out, which is what turned it from an argument into a measurement -- the flat
variant does close the loss, and on a degraded RAID5 it makes every write after
the first to a given stripe return EIO, because the sticky bit cannot say
whether the fault it records was a transient error or the missing device that
is already being counted. See needs-direction.md item 5.

## An availability check that no correct fix could pass

While measuring the de-rate, the model's `--availability` check reported it as
a spurious failure. The check was `(not acked) and len(real_faults) <=
tolerated()` -- it measures a refusal against the *nominal* profile, which is
precisely what a de-rate departs from, so it would flag any correct de-rate.

Two replacements were tried and both were wrong in a different way: "would
acking have been safe" is vacuously true once the array is past its tolerance
(a RAID5 with two devices gone is right to refuse), and adding a
within-tolerance guard still ignores that acking also creates the commitment
the write then has to satisfy. Reverted to the original rather than shipped
half-converged. The tension is real and is recorded in needs-direction.md as
part of the cost of the de-rate, not papered over in the checker.

## The residual-exposure check was checking nothing

`regress.sh` asserted that every `--in-place` and `--nodatasum` row of the sweep
violates. Four of the eight were `--in-place` rows run without `--strict`, and
in that mode a failed write is *allowed* to destroy the data it overwrote -- so
those rows can never violate and the assertion could only fail. The sweep now
runs `--in-place` with `--strict`, and the check diffs against a recorded
baseline instead, so a row moving in either direction is surfaced: a new
exposure, or one that closed and should come out of the docs.

## The scrub-pause wedge: a deadlock that cannot happen

Reading two wait conditions together produced a convincing deadlock:

    btrfs_scrub_pause():  inc pause_req;  wait until paused == running
    scrub_pause_off():    wait until pause_req == 0;  then dec paused

The recovery is deliberately absent from scrubs_running, so while it sits in
scrub_blocked_if_needed() paused is 1 and running is 0.  A commit waits for
1 == 0, which only the recovery can make true; the recovery waits for
pause_req to reach 0, which only that commit can make true.  Each is the
other's blocker.  It was reported as a deadlock twice before anything measured
it.

It cannot happen, because the two participants are never in the room together.
Instrumenting the recovery to sample fs_info->scrub_pause_req, scrubs_paused
and scrubs_running every 100ms while an artificial delay held it inside the
scrub code:

  btrfs_remount_rw()                 60 samples,  0 with a pauser
  btrfs_wib_recover_after_replay()  166 samples,  0 with a pauser

Zero in every sample of both.  The reason is structural rather than lucky:
btrfs_remount_rw() runs the recovery before btrfs_start_pre_rw_mount(), when
the filesystem is not yet taking transactions, and the after-replay recovery
runs between the log replay and the point where anything else writes.  The
commits that stat_commits counted happened around those windows, not inside
them.

What is left is real but much smaller: btrfs_scrub_raid56_recovery_begin()
documents that the recovery is kept out of the pause protocol, and
scrub_raid56_parity_stripe() puts it in.  The guard makes the code match its
comment, and costs nothing.  It is hardening against a latent inconsistency,
not a fix for a hang, and the commit that added it should not have implied
otherwise.

The measurement is worth more than the guard.  "A pauser overlapped the
recovery 0 times out of 226" is an answer; "it did not hang this time" is not.
