#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
Exhaustive model of the on-disk protocol of the btrfs RAID56 write-intent log
(fs/btrfs/raid56-wib.c) under device write failures, torn log writes at a
crash and device loss after the crash.

The companion raid56_write_hole_model.py shows that a recorded stripe is
recovered; this model checks the other half: that every stripe that must be
recovered is listed in the newest valid log block of some surviving device.

Model
-----
N devices, each with two log slots, a volatile write cache and its own "next
slot" pointer.  The in-memory state is the in-flight set, the error record
set, the last built block and the last_ok flag, as in the kernel.

Operations explored exhaustively (bounded depth):
  MARK s     record s and write the log with FUA: the block written is the
             union of the last block and the in-memory set, so no flush is
             needed.  Then the RMW writes of s are issued (they land in
             every device's cache, unflushed); the RMW may also fail on one
             device (its sector stays stale, s becomes an error record at
             DONE).  If the log write did not reach enough devices the RMW
             is not issued.
  DONE s     the RMW writes of s completed.
  PREPARE    transaction commit, first half: snapshot the set (the kernel
             does this before issuing its device barriers).  MARKs that
             happen after it add their set to the snapshot.
  COMMIT     transaction commit, second half: every device is flushed
             (each flush may fail); if every device confirmed, the stripes
             that had finished before the snapshot are dropped from the
             block, otherwise they are kept as error records; then the
             block is written with FUA.
Every device write of a log block independently succeeds, fails without
doing anything, or fails after the write happened (reported as an error,
the block may or may not survive the crash).

At every reachable state a crash is examined: the commit in progress (if
any) may have reached each device or not, or torn its slot; the caches are
lost; then every combination of up to `tolerated` devices is lost.
Recovery takes the union of the newest valid slot of every surviving
device.  Violation: a stripe with unflushed or stale data on a surviving
device, or with its RMW in flight, is not in that union.

Protocol weakenings.  The first three each produce a violation (they
correspond to defects found and fixed during the review of the kernel
code); the last two are robustness measures of the implementation that the
invariant does not depend on at the explored depths:
  --late-snapshot the set to write is taken after the flush instead of
                  before it, so a RMW completing during the flush (its
                  writes not covered by it) is dropped
  --no-merge      a MARK between PREPARE and COMMIT does not add its set
                  to the snapshot, so a RMW that starts and finishes in
                  that window is dropped although its writes may have
                  landed after the flush was issued
  --no-readd      a commit drops the finished stripes even when a device
                  did not confirm the flush
  --global-slot   one slot pointer for all devices instead of one per
                  device
  --mark-drops    the log write of a MARK also flushes and drops finished
                  stripes (the original design)
"""

import argparse
import itertools
import sys

OK, FAIL, FAIL_LANDED = "ok", "fail", "fail_landed"


class Device:
    __slots__ = ("slots", "next_slot", "cache", "stale")

    def __init__(self):
        self.slots = [None, None]      # (seq, frozenset(listed stripes)) or None
        self.next_slot = 0
        self.cache = frozenset()       # stripes with unflushed writes
        self.stale = frozenset()       # stripes whose write failed on this device

    def copy(self):
        d = Device()
        d.slots = list(self.slots)
        d.next_slot = self.next_slot
        d.cache = self.cache
        d.stale = self.stale
        return d

    def newest(self):
        valid = [s for s in self.slots if s is not None]
        return max(valid, key=lambda b: b[0])[1] if valid else frozenset()

    def key(self):
        return (tuple(self.slots), self.next_slot, self.cache, self.stale)


class State:
    __slots__ = ("devs", "inflight", "sticky", "rmw", "last", "last_ok",
                 "seq", "global_slot", "trace", "prepared")

    def __init__(self, n):
        self.devs = [Device() for _ in range(n)]
        self.inflight = frozenset()    # marked, not yet DONE
        self.sticky = frozenset()      # error records
        self.rmw = frozenset()         # RMW writes issued and not completed
        self.last = None               # last built block: frozenset
        self.last_ok = True
        self.seq = 0
        self.global_slot = 0
        self.trace = ()
        self.prepared = None           # snapshot taken by PREPARE, or None

    def copy(self):
        s = State.__new__(State)
        s.devs = [d.copy() for d in self.devs]
        for a in ("inflight", "sticky", "rmw", "last", "last_ok",
                  "seq", "global_slot", "trace", "prepared"):
            setattr(s, a, getattr(self, a))
        return s

    def key(self):
        # Devices are interchangeable for the invariant: canonicalize.
        return (tuple(sorted((d.key() for d in self.devs), key=repr)), self.inflight, self.sticky,
                self.rmw, self.last, self.last_ok, self.seq,
                self.global_slot, self.prepared)


class Model:
    def __init__(self, ndev, tolerated, stripes, depth, global_slot, no_readd,
                 mark_drops, late_snapshot, no_merge):
        self.ndev = ndev
        self.tolerated = tolerated
        self.stripes = stripes
        self.depth = depth
        self.opt_global_slot = global_slot
        self.opt_no_readd = no_readd
        self.opt_mark_drops = mark_drops
        self.opt_late_snapshot = late_snapshot
        self.opt_no_merge = no_merge
        self.seen = set()
        self.states = 0
        self.crashes = 0

    # -- the protocol --------------------------------------------------

    def commit(self, st, drop):
        """Yield successor states of a commit and the commit in progress.

        drop: a transaction commit, every device is flushed first and the
        finished stripes are dropped if every flush was confirmed.  Otherwise
        (a MARK) the block is the union of the last block and the set.
        """
        mem = st.inflight | st.sticky
        # What may be dropped is decided by the snapshot taken at PREPARE
        # (plus everything recorded since), not by the set at write time.
        keep = st.prepared if (drop and st.prepared is not None) else mem
        if drop or self.opt_mark_drops:
            # Each device's flush may fail; additionally one RMW may complete
            # during the flush (None: none does), its writes not covered.
            flush_variants = [(f, s) for f in itertools.product((True, False), repeat=self.ndev)
                              for s in (None,) + tuple(sorted(st.rmw))]
        else:
            flush_variants = [None]
        for variant in flush_variants:
            fs = st.copy()
            if drop:
                fs.prepared = None
            if variant is None:
                block = mem | (st.last or frozenset())
                if fs.last_ok and fs.last == block:
                    yield fs, True, None
                    continue
                flushes = None
            else:
                flushes, during = variant
                for dev, ok in zip(fs.devs, flushes):
                    if ok:
                        dev.cache = frozenset()
                if during is not None:
                    # Completed during the flush: data stays in the caches.
                    fs.rmw = fs.rmw - {during}
                    fs.inflight = fs.inflight - {during}
                    if any(during in d.stale for d in fs.devs):
                        fs.sticky = fs.sticky | {during}
                    for dev in fs.devs:
                        dev.cache = dev.cache | {during}
                # The block is built from the set as it is after the flush,
                # plus the snapshot (unless it is taken late).
                mem = fs.inflight | fs.sticky
                if not self.opt_late_snapshot:
                    mem = mem | keep
                if all(flushes) or self.opt_no_readd:
                    block = mem
                else:
                    fs.sticky = fs.sticky | ((st.last or frozenset()) - mem)
                    block = fs.inflight | fs.sticky | mem
                if fs.last_ok and fs.last == block:
                    yield fs, True, None
                    continue
            seq = st.seq + 1
            for outcomes in itertools.product((OK, FAIL, FAIL_LANDED), repeat=self.ndev):
                ns = fs.copy()
                ns.seq = seq
                nr_errors = 0
                for dev, oc in zip(ns.devs, outcomes):
                    slot = ns.global_slot if self.opt_global_slot else dev.next_slot
                    if oc == FAIL:
                        nr_errors += 1
                        continue
                    dev.slots[slot] = (seq, block)
                    if oc == OK:
                        dev.next_slot = 1 - slot
                    else:
                        nr_errors += 1
                enough = self.ndev - nr_errors >= self.tolerated + 1
                if self.opt_global_slot and enough:
                    ns.global_slot = 1 - ns.global_slot
                ns.last = block
                ns.last_ok = enough and nr_errors == 0
                yield ns, enough, (block, flushes, outcomes)

    def successors(self, st):
        # MARK: record a stripe and start its RMW.
        for s in self.stripes:
            if s in st.inflight:
                continue
            ms = st.copy()
            ms.inflight = ms.inflight | {s}
            if ms.prepared is not None and not self.opt_no_merge:
                ms.prepared = ms.prepared | ms.inflight | ms.sticky
            ms.trace = st.trace + (("mark", s),)
            for ns, enough, _ in self.commit(ms, False):
                ns = ns.copy()
                if not enough:
                    # btrfs_wib_mark() fails, nothing is written.
                    ns.inflight = ns.inflight - {s}
                    ns.trace = ns.trace + (("mark-failed", s),)
                    yield ns
                    continue
                # The RMW writes land in the caches; one device may fail it.
                for failing in (None,) + tuple(range(self.ndev)):
                    rs = ns.copy()
                    rs.rmw = rs.rmw | {s}
                    for i, dev in enumerate(rs.devs):
                        if i == failing:
                            dev.stale = dev.stale | {s}
                        else:
                            dev.cache = dev.cache | {s}
                    rs.trace = rs.trace + (("rmw", s, failing),)
                    yield rs
        # DONE: the RMW completed.
        for s in st.rmw:
            ns = st.copy()
            ns.rmw = ns.rmw - {s}
            ns.inflight = ns.inflight - {s}
            if any(s in d.stale for d in ns.devs):
                ns.sticky = ns.sticky | {s}
            ns.trace = st.trace + (("done", s),)
            yield ns
        # PREPARE: the transaction commit snapshots the set.
        if st.prepared is None:
            ps = st.copy()
            ps.prepared = st.inflight | st.sticky
            ps.trace = st.trace + (("prepare",),)
            yield ps
        else:
            # COMMIT: the transaction commit flushes and writes.
            cs = st.copy()
            cs.trace = st.trace + (("commit",),)
            for ns, _, _ in self.commit(cs, True):
                yield ns.copy()

    # -- the crash examination ------------------------------------------

    def check_crash(self, st, in_progress):
        """Crash now.  in_progress: (block, flushes, outcomes) of a commit
        whose device writes may be incomplete, or None."""
        per_dev = []
        for i, dev in enumerate(st.devs):
            variants = [dev]
            if in_progress is not None:
                block, flushes, outcomes = in_progress
                base = st.devs[i]
                if outcomes[i] != FAIL:
                    slot = 1 - base.next_slot if outcomes[i] == OK else \
                        (st.global_slot if self.opt_global_slot else base.next_slot)
                    # The write may be torn or may have landed (untouched is
                    # the pre-commit state, examined on its own).
                    for how in ("torn", "landed"):
                        d = base.copy()
                        d.slots[slot] = None if how == "torn" else (st.seq, block)
                        variants.append(d)
            per_dev.append(variants)
        for devs in itertools.product(*per_dev):
            self.crashes += 1
            for nlost in range(self.tolerated + 1):
                for lost in itertools.combinations(range(self.ndev), nlost):
                    survivors = [d for i, d in enumerate(devs) if i not in lost]
                    recovered = frozenset().union(*(d.newest() for d in survivors))
                    must = set(st.rmw)
                    for d in survivors:
                        must |= d.cache | d.stale
                    missing = must - recovered
                    if missing:
                        return missing, lost, devs
        return None

    def run_with_midcommit(self):
        """Like run(), but also crashes in the middle of every commit."""
        init = State(self.ndev)
        stack = [(init, 0)]
        while stack:
            st, depth = stack.pop()
            k = st.key()
            if k in self.seen:
                continue
            self.seen.add(k)
            self.states += 1
            bad = self.check_crash(st, None)
            if bad:
                return st, bad
            if depth >= self.depth:
                continue
            # Enumerate successors, examining crashes inside each commit.
            for s in self.stripes:
                if s in st.inflight:
                    continue
                ms = st.copy()
                ms.inflight = ms.inflight | {s}
                ms.trace = st.trace + (("mark", s),)
                for ns, enough, prog in self.commit(ms, False):
                    if prog is not None:
                        bad = self.check_crash(ns, prog)
                        if bad:
                            return ns, bad
            if st.prepared is not None:
                cs = st.copy()
                cs.trace = st.trace + (("commit",),)
                for ns, enough, prog in self.commit(cs, True):
                    if prog is not None:
                        bad = self.check_crash(ns, prog)
                        if bad:
                            return ns, bad
            for ns in self.successors(st):
                stack.append((ns, depth + 1))
        return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--devices", type=int, default=3)
    ap.add_argument("--tolerated", type=int, default=1)
    ap.add_argument("--stripes", type=int, default=2)
    ap.add_argument("--depth", type=int, default=5)
    ap.add_argument("--global-slot", action="store_true")
    ap.add_argument("--no-readd", action="store_true")
    ap.add_argument("--mark-drops", action="store_true")
    ap.add_argument("--late-snapshot", action="store_true")
    ap.add_argument("--no-merge", action="store_true")
    args = ap.parse_args()
    stripes = tuple("S%d" % i for i in range(args.stripes))
    m = Model(args.devices, args.tolerated, stripes, args.depth,
              args.global_slot, args.no_readd, args.mark_drops, args.late_snapshot,
              args.no_merge)
    res = m.run_with_midcommit()
    print(f"devices={args.devices} tolerated={args.tolerated} stripes={args.stripes} "
          f"depth={args.depth} global_slot={args.global_slot} no_readd={args.no_readd} "
          f"mark_drops={args.mark_drops} late_snapshot={args.late_snapshot} "
          f"no_merge={args.no_merge}: "
          f"{m.states} states, {m.crashes} crash points examined")
    if res is None:
        print("OK: every stripe that needs recovery is listed on a surviving device")
        return 0
    st, (missing, lost, devs) = res
    print("VIOLATION: stripes", sorted(missing), "not recoverable with devices",
          list(lost), "lost")
    print("  history:", " ; ".join(" ".join(str(x) for x in t) for t in st.trace))
    for i, d in enumerate(devs):
        print(f"  dev{i}: slots={d.slots} cache={sorted(d.cache)} stale={sorted(d.stale)}"
              f"{' LOST' if i in lost else ''}")
    print(f"  memory: inflight={sorted(st.inflight)} error={sorted(st.sticky)} "
          f"rmw={sorted(st.rmw)} last={sorted(st.last) if st.last else None}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
