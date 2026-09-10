#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
Exhaustive model of the btrfs scrub pause protocol.

Asks whether ANY interleaving deadlocks, rather than whether a particular test
run happened to hit one.  Written because two attempts at provoking the
suspected wedge completed without hanging, which says nothing: the absence of
a hang in one schedule is not the absence of a hang.

The three participants, transcribed from fs/btrfs/scrub.c:

  btrfs_scrub_pause()                 a transaction commit or a balance
        mutex_lock(scrub_lock)
        pause_req++
        while (paused != running) { unlock; wait(paused == running); lock }
        unlock
  btrfs_scrub_continue()              pause_req--

  scrub_pause_on()                    paused++                (no lock)
  scrub_pause_off()
        mutex_lock(scrub_lock)
        while (pause_req)  { unlock; wait(pause_req == 0); lock }
        paused--
        unlock
  scrub_blocked_if_needed()           pause_on(); pause_off()

  btrfs_scrub_dev()                   a real scrub
        mutex_lock(scrub_lock)
        __scrub_blocked_if_needed()   while (pause_req) { unlock; wait; lock }
        running++
        unlock
        ... scrub_blocked_if_needed() at its check points ...
        running--

The write-intent log's recovery calls scrub_blocked_if_needed() from
scrub_raid56_parity_stripe(), but is deliberately NOT counted in
scrubs_running (see btrfs_scrub_raid56_recovery_begin()).  That asymmetry is
what this model exists to judge.  --guard models the fix, which is to skip the
call when sctx->internal.

Reports, over every reachable interleaving:
  DEADLOCK      a state where nothing can move and something is unfinished
  paused>running  the invariant btrfs_scrub_pause() waits on being violated
"""

import argparse
import itertools
import sys

DONE = "done"


class Thread:
    """One participant.  step() returns the states reachable in one move."""

    def __init__(self, kind, tid):
        self.kind = kind
        self.tid = tid


def successors(st, threads):
    """Every (label, next_state) reachable from st by one thread taking one step."""
    req, paused, running, owner, pcs = st
    out = []

    def emit(tid, label, req2=None, p2=None, r2=None, own2="keep", pc2=None):
        n = list(pcs)
        if pc2 is not None:
            n[tid] = pc2
        out.append((f"T{tid}:{label}",
                    (req if req2 is None else req2,
                     paused if p2 is None else p2,
                     running if r2 is None else r2,
                     owner if own2 == "keep" else own2,
                     tuple(n))))

    free = owner is None

    for tid, th in enumerate(threads):
        pc = pcs[tid]
        if pc == DONE:
            continue
        k = th.kind

        if k == "pauser":
            # mutex_lock; pause_req++; while (paused != running) {...}; unlock
            if pc == 0 and free:
                emit(tid, "pause:lock", own2=tid, pc2=1)
            elif pc == 1:
                emit(tid, "pause:req++", req2=req + 1, pc2=2)
            elif pc == 2:
                if paused == running:
                    emit(tid, "pause:cond-ok", pc2=4)
                else:
                    emit(tid, "pause:unlock+wait", own2=None, pc2=3)
            elif pc == 3:
                # wait_event(paused == running), then retake the mutex
                if paused == running and free:
                    emit(tid, "pause:wake+lock", own2=tid, pc2=2)
            elif pc == 4:
                emit(tid, "pause:unlock", own2=None, pc2=5)
            elif pc == 5:
                emit(tid, "commit-work", pc2=6)
            elif pc == 6:
                emit(tid, "continue:req--", req2=req - 1, pc2=DONE)

        elif k in ("recovery", "recovery_guarded"):
            if k == "recovery_guarded":
                # The fix: sctx->internal never joins the protocol.
                if pc == 0:
                    emit(tid, "recovery:skip(guarded)", pc2=DONE)
                continue
            # if (pause_req) scrub_blocked_if_needed();
            if pc == 0:
                emit(tid, "recovery:reach-checkpoint", pc2=1)
            elif pc == 1:
                if req != 0:
                    emit(tid, "recovery:sees-req", pc2=2)
                else:
                    emit(tid, "recovery:no-req", pc2=DONE)
            elif pc == 2:
                emit(tid, "pause_on:paused++", p2=paused + 1, pc2=3)
            elif pc == 3 and free:
                emit(tid, "pause_off:lock", own2=tid, pc2=4)
            elif pc == 4:
                if req != 0:
                    emit(tid, "pause_off:unlock+wait", own2=None, pc2=5)
                else:
                    emit(tid, "pause_off:paused--/unlock",
                         p2=paused - 1, own2=None, pc2=DONE)
            elif pc == 5:
                if req == 0 and free:
                    emit(tid, "pause_off:wake+lock", own2=tid, pc2=4)

        elif k == "scrub":
            # mutex_lock; __scrub_blocked_if_needed; running++; unlock; ...
            if pc == 0 and free:
                emit(tid, "scrub:lock", own2=tid, pc2=1)
            elif pc == 1:
                if req != 0:
                    emit(tid, "scrub:blocked-unlock+wait", own2=None, pc2=2)
                else:
                    emit(tid, "scrub:running++", r2=running + 1, pc2=3)
            elif pc == 2:
                if req == 0 and free:
                    emit(tid, "scrub:wake+lock", own2=tid, pc2=1)
            elif pc == 3:
                emit(tid, "scrub:unlock", own2=None, pc2=4)
            elif pc == 4:
                # Either hit a check point, or finish.
                emit(tid, "scrub:checkpoint", pc2=5)
                emit(tid, "scrub:finish", pc2=9)
            elif pc == 5:
                emit(tid, "scrub:pause_on", p2=paused + 1, pc2=6)
            elif pc == 6 and free:
                emit(tid, "scrub:pause_off:lock", own2=tid, pc2=7)
            elif pc == 7:
                if req != 0:
                    emit(tid, "scrub:pause_off:unlock+wait", own2=None, pc2=8)
                else:
                    emit(tid, "scrub:pause_off:paused--/unlock",
                         p2=paused - 1, own2=None, pc2=4)
            elif pc == 8:
                if req == 0 and free:
                    emit(tid, "scrub:pause_off:wake+lock", own2=tid, pc2=7)
            elif pc == 9:
                emit(tid, "scrub:running--", r2=running - 1, pc2=DONE)

    return out


def explore(threads, max_states=4_000_000):
    start = (0, 0, 0, None, tuple(0 for _ in threads))
    seen = {start: None}
    stack = [start]
    deadlocks = []
    inversions = []

    while stack:
        st = stack.pop()
        succ = successors(st, threads)
        req, paused, running, owner, pcs = st

        if paused > running and not inversions:
            inversions.append(st)

        if not succ and any(pc != DONE for pc in pcs):
            deadlocks.append(st)

        for label, nxt in succ:
            if nxt not in seen:
                if len(seen) > max_states:
                    raise RuntimeError("state space too large")
                seen[nxt] = (st, label)
                stack.append(nxt)

    return seen, deadlocks, inversions


def trace(seen, st):
    path = []
    while seen.get(st):
        prev, label = seen[st]
        path.append((label, st))
        st = prev
    return list(reversed(path))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pausers", type=int, default=1,
                    help="transaction commits / balances calling btrfs_scrub_pause()")
    ap.add_argument("--scrubs", type=int, default=0,
                    help="real scrubs, which DO count in scrubs_running")
    ap.add_argument("--recovery", type=int, default=1,
                    help="write-intent log recoveries, which do NOT")
    ap.add_argument("--guard", action="store_true",
                    help="model the fix: the recovery skips the pause protocol")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    threads = []
    for _ in range(args.pausers):
        threads.append(Thread("pauser", len(threads)))
    for _ in range(args.scrubs):
        threads.append(Thread("scrub", len(threads)))
    for _ in range(args.recovery):
        threads.append(Thread("recovery_guarded" if args.guard else "recovery",
                              len(threads)))

    seen, deadlocks, inversions = explore(threads)
    desc = (f"pausers={args.pausers} scrubs={args.scrubs} "
            f"recovery={args.recovery}{' guarded' if args.guard else ''}")
    print(f"{desc}: {len(seen)} states")

    if inversions and not args.quiet:
        req, paused, running, _, _ = inversions[0]
        print(f"  paused>running reachable: paused={paused} running={running} "
              f"pause_req={req}")

    if deadlocks:
        req, paused, running, owner, pcs = deadlocks[0]
        print(f"DEADLOCK: {len(deadlocks)} state(s); first has "
              f"pause_req={req} paused={paused} running={running} pcs={pcs}")
        if not args.quiet:
            for label, _ in trace(seen, deadlocks[0]):
                print(f"    {label}")
        return 1
    print("  no deadlock in any interleaving")
    return 0


if __name__ == "__main__":
    sys.exit(main())
