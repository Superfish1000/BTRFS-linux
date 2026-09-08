#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
Exhaustive model of the RAID5/6 redundancy accounting of a single vertical
stripe, checking that btrfs never acknowledges a write that has destroyed
data it is responsible for.

The model tracks VALUES, not just fault counts, so it detects silent
corruption (a read returning something other than what was committed) and not
only "too many faults".

  State
    disk[i]      content of data stripe i on its device, or STALE
    parity       the value the P sector was computed from (RAID6: P and Q)
    committed[i] what the filesystem believes stripe i holds (None = free
                 space, not referenced by any committed transaction)
    missing[d]   the device of stripe d is absent
    cache        content the stripe cache holds for the full stripe, and
                 whether the cache is allowed to seed the next RMW

  Operations
    rmw(S, values, failures)  a read-modify-write of the data stripes in S
    full(values, failures)    a full stripe write
    lose(d)                   device d disappears after the fact

  Invariant (checked after every step and after every subsequent device loss
  within the profile's tolerance)
    every stripe i with committed[i] != None reads back as committed[i],
    where a read uses the device if present, else reconstructs from the
    parity and the other present sectors.

  Policies (what the kernel does after the writes complete)
    upstream   count only sectors with an error bit; tolerate
               bioc->max_errors, which a running device replace inflates by
               one, and a failed write to the replace target sets the
               source stripe's error bit
    fixed      count a missing device as a fault of every vertical stripe,
               tolerate real_stripes - nr_data, and never attribute a
               replace-target failure to the source

  Cache policies
    keep       a failed RMW leaves its pages in the stripe cache (upstream)
    drop       a failed RMW invalidates them (fixed)

  Results with the fixed accounting (see sweep.sh)

    RAID5 and RAID6, copy-on-write writes, on a healthy array, on a degraded
    one and while a device replace runs: no silent corruption and no
    acknowledged loss, at every depth explored.  Reverting any one of the
    three accounting rules reintroduces a violation.

    Two exposures remain, both from the same root cause: a write failure that
    stays within the profile's tolerance is acknowledged, and the sector it
    did not reach stays stale on its device while the correct content lives
    only in the parity.  Nothing tracks that latent fault afterwards.

      --nodatasum  a read of that sector returns the stale content, because
                   there is no checksum to notice and send the read to the
                   parity.  The acknowledged write is silently undone.
      --in-place   the latent fault plus a later parity write failure is two
                   faults in one vertical stripe, and the committed content
                   is gone.  Detected for checksummed data.

    rmw_retry_failed_sectors() removes the transient case; a device that
    keeps failing still leaves the window open until the next scrub.
"""

import argparse
import itertools
import sys

UNREADABLE = "unread"    # not enough redundancy left to reconstruct
GARBAGE = "garbage"      # reconstructed from a parity that no longer matches


class Stripe:
    """One vertical stripe: nr_data data sectors plus 1 (RAID5) or 2 (RAID6)
    parity sectors, each on its own device."""

    __slots__ = ("nr_data", "nr_parity", "disk", "parity", "committed",
                 "missing", "cache", "cache_ready", "replacing", "reported",
                 "recorded", "nodatasum", "spurious", "trace")

    def __init__(self, nr_data, nr_parity, replacing, nodatasum,
                 all_committed=False):
        self.nr_data = nr_data
        self.nr_parity = nr_parity
        self.replacing = replacing        # a device replace is running
        # Without checksums nothing can tell a wrong reconstruction from a
        # right one; with them (the default for btrfs data and all metadata)
        # a wrong reconstruction is refused, so it becomes a detected error.
        self.nodatasum = nodatasum
        # Initial state: data stripe 0 holds committed content, the rest is
        # free space a COW write may target; the parity matches the disk.
        self.disk = list(range(nr_data))
        # In-place writes (nodatacow, preallocated extents) overwrite sectors
        # that are already referenced, so every sector starts committed there.
        if all_committed:
            self.committed = list(range(nr_data))
        else:
            self.committed = [0] + [None] * (nr_data - 1)
        # One snapshot per parity sector: the data values that parity was
        # computed from.  P and Q are written independently, so one can be up
        # to date while the other is stale.
        self.parity = [tuple(self.disk)] * nr_parity
        self.missing = [False] * (nr_data + nr_parity)
        self.cache = None
        self.cache_ready = False
        # True once any operation on this stripe has returned an error, so the
        # filesystem knows the stripe needs attention (the write-intent log
        # keeps it recorded and the next scrub visits it).
        self.reported = False
        # True once a write completed with a fault: the write-intent log keeps
        # the stripe as an error record so the next mount scrubs it, the
        # device counter is incremented and a warning is logged.
        self.recorded = False
        # The last operation failed although the stripe still had the
        # redundancy its profile promises: a spurious failure.
        self.spurious = False
        self.trace = ()

    def copy(self):
        s = Stripe.__new__(Stripe)
        for a in Stripe.__slots__:
            v = getattr(self, a)
            s.__setattr__(a, list(v) if isinstance(v, list) else v)
        return s

    def key(self):
        return (tuple(self.disk), tuple(self.committed),
                tuple(self.missing),
                tuple(self.cache) if self.cache is not None else None,
                tuple(self.parity), self.cache_ready, self.reported,
                self.recorded, self.spurious, self.trace)

    def tolerated(self):
        return self.nr_parity

    # ---- reading ----------------------------------------------------------

    def read(self, i, extra_lost=()):
        """What a read of data stripe i returns, or UNREADABLE.

        Uses the device if it is present, otherwise reconstructs from the
        parity and the other present sectors, which is only correct if the
        parity was computed from exactly those sectors' current content.
        """
        lost = set(extra_lost)
        present = lambda d: not self.missing[d] and d not in lost

        if present(i):
            v = self.disk[i]
            # With checksums, content that is not what was committed is
            # detected and the read falls back to reconstruction (btrfs
            # retries through the next mirror, which for RAID56 rebuilds from
            # the parity).  Without them it is returned as it is.
            if self.nodatasum or self.committed[i] is None or v == self.committed[i]:
                return v

        # Reconstruct sector i from the parity and the other data sectors.
        #
        # btrfs retries a failed read through increasing mirror numbers, and
        # for RAID6 set_rbio_raid6_extra_error() makes each retry treat one
        # more stripe as failed.  So a sector that is present but silently
        # stale can be worked around as long as there are enough parity
        # equations.  Model that as: try every set of extra suspect sectors
        # the parity count allows, smallest first, and take the first
        # reconstruction that verifies.
        missing_holes = [d for d in range(self.nr_data) if not present(d)]
        others = [d for d in range(self.nr_data)
                  if d not in missing_holes and d != i]
        nr_parity_present = sum(1 for p in range(self.nr_parity)
                                if present(self.nr_data + p))
        first_answer = None

        for nr_extra in range(len(others) + 1):
            for extra in itertools.combinations(others, nr_extra):
                holes = list(missing_holes) + list(extra)
                if i not in holes:
                    holes.append(i)
                if len(holes) > nr_parity_present:
                    continue
                usable = []
                for p in range(self.nr_parity):
                    if not present(self.nr_data + p):
                        continue
                    if all(self.parity[p][d] == self.disk[d]
                           for d in range(self.nr_data) if d not in holes):
                        usable.append(p)
                if len(usable) < len(holes):
                    continue
                for p in usable:
                    rebuilt = self.parity[p][i]
                    if first_answer is None:
                        first_answer = rebuilt
                    if self.nodatasum or self.committed[i] is None:
                        # Nothing to verify against: the first answer stands.
                        return first_answer
                    if rebuilt == self.committed[i]:
                        return rebuilt
        if first_answer is not None and self.nodatasum:
            return first_answer
        return UNREADABLE

    def check(self, acked, strict, check_availability):
        """Classify what the last operation left behind.

        Returns None, or (severity, stripe, extra_lost, got, want).

        An operation that was acknowledged as successful must leave every
        committed sector readable and correct after the profile's tolerated
        number of further device losses: that is the whole promise of a RAID
        profile, and breaking it is an "acknowledged loss".

        An operation that returned an error is allowed to leave committed data
        unreadable (the caller was told, the stripe is recorded for repair and
        the next scrub visits it), but it must never leave a read returning
        WRONG data as if it were good: that is "silent corruption", the one
        outcome nothing downstream can catch for data without checksums.

        With @strict even a failed operation must not destroy data.  btrfs
        cannot promise that while a device of the stripe is missing or
        refusing writes: an interrupted parity update makes the missing
        sector unreconstructable no matter what the accounting does.  That
        residual window is what journalling the reconstructed sectors would
        close.
        """
        if self.spurious and check_availability:
            return ("spurious failure", -1, (), "EIO", "success")
        ndev = self.nr_data + self.nr_parity
        alive = [d for d in range(ndev) if not self.missing[d]]
        budget = self.tolerated() - sum(self.missing)
        for extra in range(budget + 1):
            for lost in itertools.combinations(alive, extra):
                for i in range(self.nr_data):
                    if self.committed[i] is None:
                        continue
                    got = self.read(i, lost)
                    if got == self.committed[i]:
                        continue
                    if got != UNREADABLE:
                        # A value was returned that is not what was committed
                        # -- reconstructed from a stale parity, or read from a
                        # sector a failed write left behind.  Nothing
                        # downstream can catch it.  Never acceptable.
                        return ("silent corruption", i, lost, got,
                                self.committed[i])
                    if extra == 0:
                        # The data is gone with the devices that are here now.
                        if acked:
                            return ("acknowledged loss", i, lost, got,
                                    self.committed[i])
                        if strict:
                            return ("reported loss", i, lost, got,
                                    self.committed[i])
                        continue
                    # The data is still here but would not survive the loss
                    # this profile promises to survive.  Acceptable only while
                    # the stripe is recorded for repair and the device error
                    # was counted, which is what the caller acts on.
                    if not self.recorded and not self.reported:
                        return ("unrecorded loss of redundancy", i, lost, got,
                                self.committed[i])
                    if strict:
                        return ("reduced redundancy", i, lost, got,
                                self.committed[i])
        return None

    # ---- the write path ---------------------------------------------------

    def rmw(self, write_set, newval, failures, policy, cache_policy, full):
        """One RMW or full stripe write.  See the module docstring."""
        st = self.copy()
        st.reported = False
        st.spurious = False
        st.trace = self.trace + (("full" if full else "rmw",
                                  tuple(sorted(write_set)),
                                  tuple(sorted(str(f) for f in failures))),)

        # --- read phase: what does the RMW believe the untouched sectors hold?
        believed = {}
        for d in range(st.nr_data):
            if d in write_set:
                continue
            if st.cache_ready and st.cache is not None:
                believed[d] = st.cache[d]      # served from the stripe cache
                continue
            # rmw_read_wait_recover() reads every sector, verifies the data
            # sectors against the checksum tree (fill_data_csums()) and
            # rebuilds the ones that fail from the parity.
            r = st.read(d)
            if r is UNREADABLE:
                # Cannot reconstruct: the RMW fails before writing anything.
                st.reported = True
                return st, False
            believed[d] = r
        for d in write_set:
            believed[d] = newval

        # --- write phase
        new_parity = tuple(believed[d] for d in range(st.nr_data))
        for d in write_set:
            # A device that failed (or is absent) keeps its previous content.
            if d not in failures and not st.missing[d]:
                st.disk[d] = believed[d]
        # Each parity sector is written independently.
        st.parity = list(st.parity)
        for p in range(st.nr_parity):
            if ("p%d" % p) not in failures and not st.missing[st.nr_data + p]:
                st.parity[p] = new_parity

        # --- the kernel's accounting
        faults = set()
        for d in write_set:
            if d in failures:
                faults.add(d)
        for p in range(st.nr_parity):
            if ("p%d" % p) in failures:
                faults.add(st.nr_data + p)
        # A missing device always fails the write of a sector it holds.
        for d in write_set:
            if st.missing[d]:
                faults.add(d)
        for p in range(st.nr_parity):
            if st.missing[st.nr_data + p]:
                faults.add(st.nr_data + p)

        budget = st.tolerated()
        if policy["sticky_derate"] == "count":
            # How much redundancy this stripe has already spent: every
            # committed data sector whose on-disk content is stale (its value
            # survives only in the parity), and every parity that is not
            # current.  A flat de-rate of one is not enough -- a single write
            # can fail several sectors at once, and each one costs an
            # equation.
            spent = sum(1 for d in range(st.nr_data)
                        if st.committed[d] is not None
                        and st.disk[d] != st.committed[d])
            spent += sum(1 for p in range(st.nr_parity)
                         if st.parity[p] != tuple(st.disk))
            budget -= spent
        elif policy["sticky_derate"] and st.recorded:
            # This stripe already carries an error record, so a previous write
            # spent redundancy that the current rbio cannot see: a data sector
            # it could not write is carried only by the parity, or the parity
            # itself was never updated.  error_bitmap covers one rbio, so
            # counting this write's faults against the full profile tolerance
            # would accept a second fault the stripe can no longer absorb.
            budget -= 1
        if policy["replace_inflation"] and st.replacing:
            # handle_ops_on_dev_replace() raises bioc->max_errors by one for
            # the replace target copy, but the RAID56 layer never counts a
            # target failure against it, so the extra tolerance applies to
            # real devices.
            budget += 1
        if policy["target_aliasing"] and "target" in failures:
            # A failed target copy carries the pages of the stripe it
            # duplicates, so rbio_update_error_bitmap() sets that stripe's bit.
            faults.add(0)
        if policy["missing_faults"]:
            # A missing device is a fault of the whole vertical stripe, not
            # only of the sectors this write covered.
            for d in range(st.nr_data + st.nr_parity):
                if st.missing[d]:
                    faults.add(d)

        acked = len(faults) <= budget

        # Real faults, as opposed to what the accounting believes: the replace
        # target is not part of the redundancy, so its failure is not one.
        real_faults = set()
        for d in write_set:
            if d in failures or st.missing[d]:
                real_faults.add(d)
        for p in range(st.nr_parity):
            if ("p%d" % p) in failures or st.missing[st.nr_data + p]:
                real_faults.add(st.nr_data + p)
        for d in range(st.nr_data + st.nr_parity):
            if st.missing[d]:
                real_faults.add(d)
        st.spurious = (not acked) and len(real_faults) <= st.tolerated()

        # --- effects of the acknowledgement
        if acked:
            if faults:
                # rmw_rbio() hands the stripe to btrfs_wib_done()/
                # btrfs_wib_add_sticky() as an error record and
                # rbio_account_io_error() counts it on the device.
                st.recorded = True
            # The record is deliberately NOT cleared by a fault-free write.
            # It is tempting: such an RMW reads every sector it does not
            # write, repairs any that fail their checksum, and recomputes the
            # parity, so the stripe looks whole again.  But it only repairs
            # them *in the parity computation* -- rmw_assemble_write_bios()
            # writes the data sectors this rbio supplies, not the ones it had
            # to reconstruct, so a sector left stale by an earlier failed
            # write stays stale on disk and is still carried only by the
            # parity.  Redundancy is not restored, and clearing the record
            # here makes the model report "unrecorded loss of redundancy" at
            # every width from three data stripes up.
            #
            # Only something that rewrites the stale sector -- a scrub, or an
            # RMW taught to write back what it reconstructed -- restores it.
            for d in write_set:
                st.committed[d] = newval       # the transaction references it
            st.cache = [believed[d] for d in range(st.nr_data)]
            # full stripe writes are not cached
            st.cache_ready = not full
            if policy["drop_cache_on_fault"] and faults:
                # rmw_rbio() clears RBIO_CACHE_READY_BIT only when the write
                # failed outright, so a write accepted *within* the tolerance
                # still seeds the cache -- with content a device did not take.
                # The next RMW is then served believed values, succeeds where
                # it should have found the stripe unreadable, and writes a
                # parity encoding sectors that are not on disk.
                #
                # Dropping it instead makes that RMW read the stale sector,
                # fail its checksum and reconstruct it from the parity, which
                # both yields the true value and proves the parity still
                # usable.  (Without checksums the stale sector is trusted
                # either way; that is the nodatasum exposure.)
                st.cache_ready = False
        else:
            # The write was refused.  An in-place write may have destroyed the
            # old content of the sectors it targeted; that is the documented
            # semantics of a failed overwrite, not a redundancy failure.
            st.reported = True
            # A failed write is handed to the write-intent log as an error
            # record too, so the stripe is scrubbed at the next mount.
            st.recorded = True
            for d in write_set:
                if st.disk[d] != st.committed[d]:
                    st.committed[d] = None
            if cache_policy == "keep":
                st.cache = [believed[d] for d in range(st.nr_data)]
                st.cache_ready = not full
            else:
                st.cache = None
                st.cache_ready = False
        return st, acked

    def lose(self, d):
        st = self.copy()
        st.missing[d] = True
        st.trace = self.trace + (("lose", d),)
        return st


def successors(st, policy, cache_policy, nextval, in_place):
    ndev = st.nr_data + st.nr_parity
    # Every subset of data stripes can be written (non-empty).  Copy-on-write
    # only ever targets free space; with in_place, referenced sectors can be
    # overwritten too (nodatacow, preallocated extents).
    for r in range(1, st.nr_data + 1):
        for write_set in itertools.combinations(range(st.nr_data), r):
            if not in_place and any(st.committed[d] is not None for d in write_set):
                continue
            full = (r == st.nr_data)
            # Which devices fail this write: any subset of the ones involved.
            candidates = [d for d in write_set]
            candidates += ["p%d" % p for p in range(st.nr_parity)]
            if st.replacing:
                candidates.append("target")
            for nf in range(len(candidates) + 1):
                for failures in itertools.combinations(candidates, nf):
                    yield st.rmw(set(write_set), nextval, set(failures),
                                 policy, cache_policy, full)
    # A device can disappear.
    for d in range(ndev):
        if not st.missing[d]:
            # Losing a device is not an operation anyone acknowledged; the
            # invariant for it is the one of the state it came from.
            yield st.lose(d), False


def explore(nr_data, nr_parity, depth, policy, cache_policy, replacing,
            start_missing, in_place, strict, nodatasum, availability):
    start = Stripe(nr_data, nr_parity, replacing, nodatasum,
                   all_committed=in_place)
    for d in start_missing:
        start.missing[d] = True
    seen = set()
    stack = [(start, 0, True)]
    nstates = 0
    while stack:
        st, d, acked = stack.pop()
        k = (st.key(), acked)
        if k in seen:
            continue
        seen.add(k)
        nstates += 1
        bad = st.check(acked, strict, availability)
        if bad:
            return nstates, st, bad
        if d == depth:
            continue
        for nxt, nacked in successors(st, policy, cache_policy, 100 + d,
                                      in_place):
            stack.append((nxt, d + 1, nacked))
    return nstates, None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", type=int, default=2, help="data stripes")
    ap.add_argument("--parity", type=int, default=1, help="1 = RAID5, 2 = RAID6")
    ap.add_argument("--depth", type=int, default=3)
    ap.add_argument("--policy", choices=["upstream", "fixed"], default="fixed",
                    help="shorthand for the three accounting flags below")
    ap.add_argument("--replace-inflation", action="store_true",
                    help="raise the fault budget by one while a device "
                         "replace is running (upstream)")
    ap.add_argument("--target-aliasing", action="store_true",
                    help="a failed replace-target copy counts as a failure of "
                         "the stripe it duplicates (upstream)")
    ap.add_argument("--no-drop-cache-on-fault", action="store_true",
                    help="let a write accepted within the tolerance still "
                         "seed the stripe cache")
    ap.add_argument("--no-sticky-derate", action="store_true",
                    help="do not reduce the fault budget of a stripe that "
                         "already carries an error record")
    ap.add_argument("--no-missing-faults", action="store_true",
                    help="do not count a missing device as a fault of the "
                         "sectors this write did not cover (upstream)")
    ap.add_argument("--cache", choices=["keep", "drop"], default="drop")
    ap.add_argument("--replacing", action="store_true",
                    help="a device replace is running")
    ap.add_argument("--missing", type=int, nargs="*", default=[],
                    help="devices already missing at the start")
    ap.add_argument("--in-place", action="store_true",
                    help="allow overwriting referenced sectors (nodatacow)")
    ap.add_argument("--nodatasum", action="store_true",
                    help="the data has no checksums, so a wrong "
                         "reconstruction cannot be detected")
    ap.add_argument("--availability", action="store_true",
                    help="also flag writes refused although the stripe still "
                         "had the redundancy its profile promises")
    ap.add_argument("--strict", action="store_true",
                    help="also require that no committed data is lost on a "
                         "stripe whose operations reported an error "
                         "(unachievable while degraded without journalling)")
    args = ap.parse_args()

    if args.policy == "upstream":
        policy = dict(replace_inflation=True, target_aliasing=True,
                      missing_faults=False, sticky_derate=False,
                      drop_cache_on_fault=False)
    else:
        policy = dict(replace_inflation=False, target_aliasing=False,
                      missing_faults=True, sticky_derate="count",
                      drop_cache_on_fault=True)
    if args.replace_inflation:
        policy["replace_inflation"] = True
    if args.target_aliasing:
        policy["target_aliasing"] = True
    if args.no_missing_faults:
        policy["missing_faults"] = False
    if args.no_sticky_derate:
        policy["sticky_derate"] = False
    if args.no_drop_cache_on_fault:
        policy["drop_cache_on_fault"] = False

    n, bad_state, bad = explore(args.data, args.parity, args.depth,
                                policy, args.cache, args.replacing,
                                args.missing, args.in_place, args.strict,
                                args.nodatasum, args.availability)
    flags = ",".join(k for k, v in sorted(policy.items()) if v) or "none"
    desc = (f"raid{5 if args.parity == 1 else 6} data={args.data} depth={args.depth} "
            f"accounting={flags} cache={args.cache} "
            f"replacing={args.replacing} missing={args.missing} "
            f"in_place={args.in_place} nodatasum={args.nodatasum} "
            f"strict={args.strict}")
    print(f"{desc}: {n} states examined")
    if bad:
        kind, i, lost, got, want = bad
        print(f"VIOLATION ({kind}): committed data of stripe {i} reads back as "
              f"{got!r}, expected {want!r}, with devices {list(lost)} "
              f"additionally lost")
        print("  history: " + " ; ".join(str(t) for t in bad_state.trace))
        print(f"  disk={bad_state.disk} parity={bad_state.parity} "
              f"committed={bad_state.committed} missing={bad_state.missing}")
        return 1
    print("OK: no silent corruption and no acknowledged loss" +
          ("; and no loss at all" if args.strict else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
