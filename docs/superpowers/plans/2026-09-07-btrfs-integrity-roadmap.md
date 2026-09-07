# BTRFS data integrity: programme scope and roadmap

This is the spec the implementation plans in this directory argue from. It
records what was asked for, what the scope check concluded, and what each
unit of work is — so that a plan can be written for one unit without
re-deriving the whole landscape.

## What was asked for

Build out, as one effort:

- **(A)** the 20 data-integrity improvements identified in the report
  *After the Write Hole*;
- **(B)** "all the active issues for BTRFS";
- **(C)** bringing RAID5/6 onto the RAID Stripe Tree.

## Scope check: this is not one plan

A plan must cover one subsystem and produce working, testable software on
its own. The three parts fail that test in three different ways.

**(A) spans at least six subsystems** — RAID5/6 reconstruction, scrub, the
mirrored read-repair path, the superblock write path, device open and scan,
and a new nodatacow-checksum feature that reaches into inode flags, the tree
log and btrfs-progs. The remaining work per item is small and independently
reviewable; bundling it destroys exactly that property.

**(B) is a backlog, not a unit of software.** It spans two repositories,
several user reports against 6.x kernels that are unverified on 7.3-rc2, and
documentation status ratings that no patch can change. A plan whose scope is
"the defect landscape" has no definition of done. It belongs in periodic
triage that produces issues, which then feed the units below.

**(C) is a multi-year upstream project blocked on an unresolved design
question.** See below.

Measured against this branch's own evidence: closing one defect — the write
hole — took 5,580 insertions across 28 files. Twenty further improvements at
a fifth of that scale is well over 20,000 lines. The binding constraint is
not typing but reviewability.

## Global constraints

Every plan in this directory inherits these. They are requirements, not
aspirations, and each one names how it is demonstrated.

1. **Crash safety.** No sequence of writes may leave the filesystem unable
   to recover, at any interruption point. Demonstrated with
   `tools/testing/btrfs/uml/` crash points 1–4, not by inspection.
2. **Interrupt and cancellation safety.** Killed mounts, `btrfs scrub
   cancel`, `btrfs replace cancel`, unmount racing in-flight work, and
   remount ro↔rw must leave consistent state. Every new `wait_event()` must
   justify being uninterruptible or use a killable variant.
3. **Timeout and hang resistance.** Every wait must state what happens if
   the awaited event never arrives. No new lock-order inversions; validated
   under `CONFIG_PROVE_LOCKING`. A device that stops responding must not
   wedge the transaction machinery.
4. **Misbehaving devices.** Correct behaviour is required against devices
   that lose writes silently, lie about flushes, misdirect writes, or
   disappear and return with stale content. Where a class of misbehaviour
   cannot be defended against, it is documented as a limit rather than
   left implied.
5. **No unverified reconstruction is ever persisted.** Reconstructed data
   may be handed to a reader; it may only be written back when something
   established it is correct.
6. **Every fix carries a test that fails without it.** A fix whose test
   passes before the change has not been demonstrated.

## Units of work

Each ships working, testable software on its own unless noted.

### Near term

| Unit | Scope | Size |
|------|-------|------|
| **A-1** | RAID5/6 rebuild verification: load checksums on the recovery path, verify metadata, propagate the verdict to the repair write-back gate | ~400–700 lines, 6–10 patches |
| **A-2** | Scrub RAID5/6 correctness and accounting: stale-buffer parity rewrite, the discarded RAID6 second syndrome, invisible parity repairs, broken unrepaired-sector accounting | ~500–900 lines |
| **A-4** | The mirrored-profile equivalent of the accepted-write defect: retry, record, and stop the read policy making divergence a coin flip | ~150–350 lines |
| **A-5** | Superblock and flush-failure integrity: escalate primary submission failures, skip supers for a device whose flush failed, make the backup mirrors usable | ~300–600 lines |
| **A-7** | Lying-flush audit harness. Tooling only; it is the missing prerequisite for demonstrating A-5 and A-6 | small |

### Then

| Unit | Scope | Note |
|------|-------|------|
| **A-6** | Stale-member detection at mount | changes mount policy; needs its own override story |
| **A-3** | Scrub compare-copies mode for unchecksummed data | worth more *after* A-8 shrinks that population |
| **A-8** | Opt-in detect-only checksums for nodatacow | the highest-leverage feature; keeps "refuse unverifiable rebuilds" from becoming an availability regression |
| **A-9** | Checksummed parity | format change; only after A-8 settles where checksums live for data the csum tree does not cover |

### RAID Stripe Tree track

**C-1** (real tree-checker validation of stripe extent items) and **C-2**
(selftests beyond RAID1) are independently useful, upstreamable as they
stand, and prerequisites for everything else here. **C-3** inverts the
lookup so the item supplies the device rather than merely an offset on a
device the chunk map already chose.

Everything past that is gated. See below.

## Why RAID5/6 on the RAID Stripe Tree cannot be planned to completion

Three findings, each verified against the code in this tree.

**The format cannot express a RAID5/6 stripe.** A stride is 16 bytes of
`{devid, physical}` with no role, length or generation
(`include/uapi/linux/btrfs_tree.h:753-763`), and every stride is defined to
cover the whole key range — a statement about *copies*. The stride count
comes from `btrfs_bg_type_to_factor()`, which returns `ncopies`: **1** for
RAID5 and RAID6. Parity has no logical address to be keyed by. This needs a
new item type or new stride semantics, and therefore a new incompat bit.

**RAID5/6 never reaches the lookup, by design.** `btrfs_map_block()` has a
separate open-coded RAID56 branch (`fs/btrfs/volumes.c:7397-7424`) that
bypasses `set_io_stripe()`, the only place the tree is consulted. The one
merged change specifically about RAID56 and the RST is the one that
*separated* them. Flipping the profile mask would not cause a single byte of
the tree to be read.

**The blocking question is a design objection, not an implementation gap.**
Copy-on-write parity needs an allocator that never writes into a row holding
referenced sectors. Both candidate policies have been objected to on
linux-btrfs by the RAID56 maintainer — padding rows wastes space, and
reusing free space within existing rows can put a block and its own parity
on one disk. C-4 through C-7 can be built competently and rejected.

RST itself remains `CONFIG_BTRFS_EXPERIMENTAL` three years after merging,
and its on-disk format is explicitly not final.

**Honest estimate:** 60–100 patches, 5,000–8,000 kernel lines plus a
comparable amount in btrfs-progs, two to three years for a full-time owner.
That is not pessimism; it is the RST's own history, and RST was simpler.

**Smallest genuinely useful first step:** C-1 and C-2. They harden what
exists, are upstreamable immediately, and are required by every variant of
the larger design.

### Sourcing caveat

`lore.kernel.org`, `git.kernel.org`, `patchwork.kernel.org` and
`bugzilla.kernel.org` are unreachable from the environment this research ran
in. Merged work was verified through the tree and the GitHub commit API;
**posted-but-unmerged RFCs could not be enumerated.** Treat "nothing has been
posted" as unverified, and re-check before committing to any of the C track.

## What (B) actually contains

Sourced from the btrfs documentation and the btrfs-progs tracker, not from
recollection. The RAID5/6 entries are: the profile is formally unstable; the
write hole (addressed on this branch); metadata power-failure safety is "not
100%"; scrub runs on every device at once and the workaround corrupts device
statistics (open since 2020); no configurable stripe width; space reporting
is wrong alongside other profiles; device replace and delete abort when any
block cannot be reconstructed. Beyond RAID5/6: zoned mode is not feature
complete, offline `btrfs check` has no parity awareness at all, and there are
open replace, balance and compression bugs in the tracker.

Several of these are documented design limitations rather than defects. They
belong in triage, feeding the units above.
