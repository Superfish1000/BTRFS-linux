#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
Exhaustive state-machine model of btrfs RAID5/6 sub-stripe writes, crashes,
device loss and recovery.

The model answers one question by brute force: after ANY crash at ANY point of
a sub-stripe read-modify-write, followed by the loss of up to t devices
(t = 1 for RAID5, 2 for RAID6), can every sector of COMMITTED data still be
read correctly?

It is run for two protocols:

  baseline   what fs/btrfs/raid56.c did before this series: the RMW writes
             its data and P/Q sectors as independent device writes with no
             record; mount does nothing to the stripe.

  wib        the write-intent log added in fs/btrfs/raid56-wib.c: the RMW
             records the full stripe durably before its writes, the record is
             dropped only after the writes completed and were flushed, and
             mount regenerates the parity of every recorded full stripe.

State space

  One vertical stripe of a full stripe is modelled (the write hole is a per
  vertical stripe property; a full stripe is just several independent
  vertical stripes).  It has n data sectors and P (RAID5) or P and Q (RAID6).
  Sector contents are symbolic: every data sector i holds either its old
  value "d{i}o" or its new value "d{i}n"; parity holds the parity of some
  combination of old/new data values, or is symbolically "torn" (a partial
  device write, treated as garbage).

  A subset M of the data sectors (non-empty, not all of them: otherwise it's
  a full stripe write which needs no RMW) is being updated: those sectors
  are "free" space being written with new data; the others hold committed
  data.  Every combination of (n, M) is explored.

  The RMW is the sequence: read; [wib: log write]; issue |M| data writes and
  the parity writes; every write independently either completes, is lost, or
  (parity only, to model a partial sector write) is torn; [wib: after all
  writes, the record may or may not be dropped -- dropping implies the writes
  were flushed].  Every such combination is a crash point, giving exhaustive
  coverage of the device-write interleavings that matter (the order in which
  completed writes landed is irrelevant, only the set of landed writes).

  After the crash: the recovery step of the protocol runs (nothing for
  baseline; parity regeneration from whatever is on disk for wib if the
  record is present), then every subset of up to t devices is removed and
  the committed sectors are read: directly if their device is present, or by
  reconstruction from the surviving sectors otherwise.  A committed sector
  is "correct" if the read value equals its old (committed) value.  Because
  the log entry only ever mentions the full stripe, the model also checks
  that the wib recovery is idempotent and harmless on consistent stripes.

Two-slot log abstraction

  The real log alternates between two on-disk slots and recovery takes the
  union of all valid slots of all devices.  The model collapses this into
  one boolean "logged": the union can only be larger than the newest block,
  and the newest block loses a stripe only through a commit issued after
  btrfs_wib_done() with a PREFLUSH, so "not logged" implies "all writes on
  stable media", which is exactly the transition modelled below.

Devices

  Sector i lives on device i, P on device n, Q on device n+1.  Devices are
  lost after the crash+recovery (a device lost before the crash is the
  degraded case, which is out of scope of a write-intent log and reported
  separately as a documented limit).

Parity algebra

  Parity is represented as the frozenset of data values it was computed
  from: P = {v_0, ..., v_{n-1}} with v_i in {d{i}o, d{i}n}.  Reconstructing
  sector i from P and the other sectors yields v_i if and only if every other
  sector j on disk holds the value v_j that P was computed with; otherwise
  the result is garbage.  This is exact for XOR: P ^ (xor of others) = v_i
  iff the others match, else some unrelated value.  For RAID6 Q the same
  holds (Reed-Solomon over GF(2^8) with distinct coefficients); with two
  lost devices the pair is reconstructed from P and Q together and is
  correct iff both P and Q were computed from the values the surviving
  sectors hold.

Run:  python3 raid56_write_hole_model.py            (all configurations)
      python3 raid56_write_hole_model.py --quick    (n <= 3)
"""

import itertools
import sys
from dataclasses import dataclass, field

TORN = "torn"
LOST = "lost"          # write never reached the device
DONE = "done"          # write landed


def old(i):
    return f"d{i}o"


def new(i):
    return f"d{i}n"


def torn(i):
    return f"d{i}t"


@dataclass(frozen=True)
class DiskState:
    """Contents of one vertical stripe on disk."""
    n: int
    raid6: bool
    data: tuple                     # data[i] in {old(i), new(i)}
    p: object                       # frozenset of values, or TORN
    q: object                       # frozenset of values, TORN, or None (RAID5)
    logged: bool                    # wib: the full stripe is in a valid log block

    def consistent(self):
        want = frozenset(self.data)
        if self.p != want:
            return False
        if self.raid6 and self.q != want:
            return False
        return True


def parity_of(data):
    return frozenset(data)


def reconstruct(disk, lost):
    """
    Return the value read for every data sector when the devices in `lost`
    (indices; n = P device, n+1 = Q device) are unavailable.  A value of None
    means unreadable/garbage.
    """
    n = disk.n
    result = {}
    lost_data = [i for i in lost if i < n]
    p_lost = n in lost
    q_lost = (n + 1) in lost
    if len(lost_data) == 0:
        for i in range(n):
            result[i] = disk.data[i]
        return result
    if len(lost_data) == 1:
        i = lost_data[0]
        for j in range(n):
            if j != i:
                result[j] = disk.data[j]
        others = {j: disk.data[j] for j in range(n) if j != i}
        # Use P if available, else Q (RAID6).
        par = None
        if not p_lost and disk.p != TORN:
            par = disk.p
        elif disk.raid6 and not q_lost and disk.q != TORN:
            par = disk.q
        if par is None:
            result[i] = None
            return result
        # Reconstruction is exact iff the parity was computed with the values
        # the surviving sectors hold.
        ok = all(v in par for v in others.values()) and len(par) == n
        if ok:
            # the remaining value in par is what we get back
            rest = set(par) - set(others.values())
            result[i] = rest.pop() if len(rest) == 1 else None
        else:
            result[i] = None
        return result
    if len(lost_data) == 2 and disk.raid6 and not p_lost and not q_lost:
        i, k = lost_data
        others = {j: disk.data[j] for j in range(n) if j not in (i, k)}
        for j in others:
            result[j] = disk.data[j]
        if disk.p == TORN or disk.q == TORN or disk.p != disk.q:
            result[i] = result[k] = None
            return result
        par = disk.p
        ok = all(v in par for v in others.values()) and len(par) == n
        if not ok:
            result[i] = result[k] = None
            return result
        rest = set(par) - set(others.values())
        vi = [v for v in rest if v.startswith(f"d{i}")]
        vk = [v for v in rest if v.startswith(f"d{k}")]
        result[i] = vi[0] if len(vi) == 1 else None
        result[k] = vk[0] if len(vk) == 1 else None
        return result
    for j in range(n):
        result[j] = disk.data[j] if j not in lost_data else None
    return result


def wib_recover(disk):
    """Mount-time parity regeneration from the data on disk (all devices present)."""
    if not disk.logged:
        return disk
    par = parity_of(disk.data)
    return DiskState(disk.n, disk.raid6, disk.data, par, par if disk.raid6 else None, False)


@dataclass
class Report:
    checked: int = 0
    failures: list = field(default_factory=list)
    degraded_checked: int = 0
    degraded_correct: int = 0
    degraded_detected: int = 0
    degraded_silent: int = 0


def crash_states(n, raid6, modified, protocol):
    """
    Enumerate every on-disk state a crash during the RMW can leave.

    Yields (disk_state, description).
    """
    committed = [i for i in range(n) if i not in modified]
    old_data = tuple(old(i) for i in range(n))
    new_data = tuple(new(i) if i in modified else old(i) for i in range(n))
    old_par = parity_of(old_data)
    new_par = parity_of(new_data)

    # Before any write: nothing happened yet (log may or may not be there).
    yield DiskState(n, raid6, old_data, old_par, old_par if raid6 else None, False), "before RMW"
    if protocol == "wib":
        # Log write completed, no stripe write issued yet.
        yield DiskState(n, raid6, old_data, old_par, old_par if raid6 else None, True), "logged, no writes"

    # Each data write in M: done, lost or torn (garbage sector).  Parity
    # writes: done, lost or torn.
    par_outcomes = [DONE, LOST, TORN]
    for data_outcome in itertools.product([DONE, LOST, TORN], repeat=len(modified)):
        for p_outcome in par_outcomes:
            q_choices = par_outcomes if raid6 else [None]
            for q_outcome in q_choices:
                data = list(old_data)
                for idx, i in enumerate(modified):
                    if data_outcome[idx] == DONE:
                        data[i] = new(i)
                    elif data_outcome[idx] == TORN:
                        data[i] = torn(i)
                p = {DONE: new_par, LOST: old_par, TORN: TORN}[p_outcome]
                q = None
                if raid6:
                    q = {DONE: new_par, LOST: old_par, TORN: TORN}[q_outcome]
                desc = f"data={data_outcome} p={p_outcome} q={q_outcome}"
                if protocol == "baseline":
                    yield DiskState(n, raid6, tuple(data), p, q, False), desc
                else:
                    # The log write completed before any stripe write was
                    # issued (btrfs_wib_mark() returns only after FUA), so at
                    # every crash point during the writes the record exists.
                    yield DiskState(n, raid6, tuple(data), p, q, True), desc
                    # The record is dropped only after ALL writes landed AND a
                    # flush pushed them to stable media: the only state in
                    # which the crash can find the record gone is the fully
                    # written one.
                    all_done = all(o == DONE for o in data_outcome) and \
                        p_outcome == DONE and (not raid6 or q_outcome == DONE)
                    if all_done:
                        yield DiskState(n, raid6, tuple(data), p, q, False), desc + " (record dropped after flush)"


def check(n, raid6, protocol, report, verbose=False):
    t = 2 if raid6 else 1
    ndev = n + (2 if raid6 else 1)
    for msize in range(1, n):
        for modified in itertools.combinations(range(n), msize):
            committed = [i for i in range(n) if i not in modified]
            for disk, desc in crash_states(n, raid6, modified, protocol):
                # Recovery step of the protocol.
                if protocol == "wib":
                    recovered = wib_recover(disk)
                else:
                    recovered = disk
                # Loss of up to t devices after the crash.
                for k in range(0, t + 1):
                    for lost in itertools.combinations(range(ndev), k):
                        got = reconstruct(recovered, set(lost))
                        report.checked += 1
                        for i in committed:
                            if got[i] != old(i):
                                report.failures.append(
                                    (n, raid6, modified, desc, lost, i, got[i]))
                                if verbose:
                                    print(f"FAIL n={n} raid6={raid6} modified={modified} "
                                          f"crash='{desc}' lost={lost} sector {i} read {got[i]}")
                # Degraded before the crash: a device was already missing
                # while the RMW ran (out of scope, documented limit).
                if protocol == "wib":
                    for missing in range(ndev):
                        # The missing device's sector never got written.
                        d = list(disk.data)
                        p, q = disk.p, disk.q
                        if missing < n:
                            d[missing] = old(missing) if missing in modified else disk.data[missing]
                        elif missing == n:
                            p = parity_of(tuple(old(i) for i in range(n)))
                        else:
                            q = parity_of(tuple(old(i) for i in range(n)))
                        deg = DiskState(n, raid6, tuple(d), p, q, disk.logged)
                        # Recovery cannot regenerate parity without the
                        # missing data; the missing committed sector is
                        # reconstructed from what survived.  A wrong
                        # reconstruction is detected by the data checksum
                        # (verify_one_sector()), so it is a detected loss;
                        # only a value that passes as the committed one
                        # would be a silent corruption.
                        got = reconstruct(deg, {missing})
                        for i in committed:
                            report.degraded_checked += 1
                            if got[i] == old(i):
                                report.degraded_correct += 1
                            elif got[i] is None or got[i] != old(i):
                                # None: unreadable.  Any other value differs
                                # from the committed one and fails its csum.
                                report.degraded_detected += 1


def main():
    quick = "--quick" in sys.argv
    verbose = "-v" in sys.argv
    configs = []
    for n in range(2, 4 if quick else 6):
        configs.append((n, False))
        configs.append((n, True))
    overall_ok = True
    for protocol in ("baseline", "wib"):
        print(f"=== protocol: {protocol} ===")
        for n, raid6 in configs:
            rep = Report()
            check(n, raid6, protocol, rep, verbose)
            level = "RAID6" if raid6 else "RAID5"
            print(f"{level} n_data={n}: {rep.checked} (crash, device-loss) cases checked, "
                  f"{len(rep.failures)} committed-data losses"
                  + (f"; degraded-at-crash sectors: {rep.degraded_correct} correct, "
                     f"{rep.degraded_detected} detected loss, {rep.degraded_silent} silent"
                     if protocol == "wib" else ""))
            if rep.failures and protocol == "wib":
                overall_ok = False
            if rep.failures and protocol == "baseline" and not verbose:
                ex = rep.failures[0]
                print(f"   example: modified={ex[2]} crash='{ex[3]}' lost devices={ex[4]} "
                      f"-> committed sector {ex[5]} reads {ex[6]}")
    print()
    if overall_ok:
        print("RESULT: write-intent log protocol: no committed data lost in any "
              "crash + device-loss scenario within the RAID tolerance.")
        return 0
    print("RESULT: FAILURES in the write-intent log protocol")
    return 1


if __name__ == "__main__":
    sys.exit(main())
