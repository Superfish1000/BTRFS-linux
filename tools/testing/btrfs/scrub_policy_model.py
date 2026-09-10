#!/usr/bin/env python3
"""Exhaustive model of what a RAID5/6 scrub may do to a stripe whose data
carries no checksum.

Why this exists
---------------
Three fixes were proposed for "plain btrfs scrub destroys nodatacow data that
was still recoverable", and all three were withdrawn on an argument rather
than a measurement:

  T1  RAID6 P/Q localisation      withdrawn: the signature was said to be
                                  symmetric between "a data column is stale"
                                  and "both parities are stale"
  T2  consult the write-intent    withdrawn: the stale record is per-mount,
      log's stale record          and the reproduction crosses a mount
  T3  refuse and report           withdrawn: breaks device replace, and
                                  leaves stripes unrepaired that today's
                                  code repairs correctly

An argument is not a result.  This enumerates every write history up to a
bounded depth, applies each candidate policy, and reports what each one
actually does -- so "unsound" means a printed counterexample and "sound"
means no counterexample exists within the bound, not that nobody thought of
one.

The model
---------
One full stripe, nr_data data columns and nr_parity parity devices, each on
its own device.  Values are opaque integers; the point is never arithmetic,
it is which copy holds which value.

  disk[i]        what the data device for column i physically holds
  committed[i]   the value the filesystem acknowledged for column i
  par[k]         the DATA VECTOR the parity device k was computed from

Representing a parity as the vector it was computed from is exact for this
question.  Reconstructing column i from parity k and the other columns solves
the parity equation, which yields par[k][i] when par[k] agrees with the disk
everywhere else, and a value nothing ever committed when it does not.

A read-modify-write computes the new parity from what it read plus what it is
about to write, and issues data and parity writes concurrently.  So a parity
write that lands while the data write it describes does not leaves the parity
holding the ONLY copy of the acknowledged value.  That is the whole subject.

What is measured
----------------
  DESTROY    a committed value that was recoverable before the scrub is not
             recoverable after it: the scrub caused the loss
  MISREPAIR  the scrub wrote a value onto a data device that was never
             committed there: active corruption, strictly worse than DESTROY
  NOREPAIR   the scrub left the stripe without full redundancy in a case
             where the upstream policy would have restored it: the price of
             refusing
  REPLHOLE   a device replace was running and the scrub produced no content
             for the replacement device

Negative control: the "upstream" policy MUST report DESTROY.  It is the bug
this whole series is about, reproduced under UML at 8 of 32 blocks.  A run
where upstream comes out clean means the model is wrong, and --self-check
fails the program rather than printing a reassuring zero.
"""

import argparse
import itertools
import sys

UNREADABLE = "unreadable"


# --------------------------------------------------------------------------
# state
# --------------------------------------------------------------------------

class Stripe:
    __slots__ = ("nr_data", "nr_parity", "disk", "committed", "par",
                 "missing", "sticky", "stale", "stale_par", "replacing",
                 "trace", "reported")

    def __init__(self, nr_data, nr_parity, replacing=None):
        self.nr_data = nr_data
        self.nr_parity = nr_parity
        # Every column starts holding committed content: this models the
        # nodatacow / prealloc case, where a write overwrites live data in
        # place.  That is the only case the bug needs, and starting anywhere
        # else would understate it.
        self.disk = list(range(nr_data))
        self.committed = list(range(nr_data))
        self.par = [tuple(self.disk)] * nr_parity
        self.missing = [False] * (nr_data + nr_parity)
        # What the write-intent log records.  sticky is persisted across a
        # mount; stale and stale_par are not, today.
        self.sticky = frozenset()
        self.stale = frozenset()
        self.stale_par = frozenset()
        self.replacing = replacing     # device index being replaced, or None
        self.reported = False          # the scrub told the user something
        self.trace = ()

    def copy(self):
        s = Stripe.__new__(Stripe)
        for a in Stripe.__slots__:
            v = getattr(self, a)
            setattr(s, a, list(v) if isinstance(v, list) else v)
        return s

    def key(self):
        # Deliberately excludes trace: two states with the same content
        # behave identically from here on, however they were reached.
        return (tuple(self.disk), tuple(self.committed), tuple(self.par),
                tuple(self.missing), self.sticky, self.stale, self.stale_par,
                self.replacing, self.reported)

    def present(self, d, lost=()):
        return not self.missing[d] and d not in lost

    # ---- reconstruction ---------------------------------------------------

    def recover(self, i, lost=(), avoid_stale_par=False):
        """The value a read of column i returns, or UNREADABLE.

        No checksums: whatever comes back is returned as data.  Reconstruction
        picks the first parity that is usable, which is what the kernel does --
        it has nothing to prefer one over another with, unless the log's
        record of which parities a failed write left stale is consulted
        (@avoid_stale_par).
        """
        if self.present(i, lost):
            return self.disk[i]
        holes = [d for d in range(self.nr_data) if not self.present(d, lost)]
        for k in range(self.nr_parity):
            if not self.present(self.nr_data + k, lost):
                continue
            if avoid_stale_par and k in self.stale_par:
                continue
            if len(holes) > 1:
                # One parity can only solve for one unknown.  Two unknowns
                # need two parities that agree with the disk elsewhere AND
                # with each other, which only holds when they are the same
                # vector.
                usable = [p for p in range(self.nr_parity)
                          if self.present(self.nr_data + p, lost)
                          and not (avoid_stale_par and p in self.stale_par)]
                if len(usable) < len(holes):
                    return UNREADABLE
                if len({self.par[p] for p in usable}) != 1:
                    # Different vectors: the solution satisfies both equations
                    # but matches neither vector.  A value nothing committed.
                    return "garbage"
                k = usable[0]
            if all(self.par[k][d] == self.disk[d]
                   for d in range(self.nr_data) if d not in holes):
                return self.par[k][i]
            return "garbage"
        return UNREADABLE

    def survives(self, lost=()):
        """Every committed value still readable and correct after losing the
        devices in @lost."""
        for i in range(self.nr_data):
            if self.recover(i, lost) != self.committed[i]:
                return False
        return True

    def recoverable_now(self):
        """The set of extra device losses the stripe currently survives,
        expressed as: is every committed value readable with no further loss,
        and with each single further loss."""
        out = set()
        if self.survives():
            out.add(())
        for d in range(self.nr_data + self.nr_parity):
            if self.missing[d]:
                continue
            if self.survives((d,)):
                out.add((d,))
        return frozenset(out)

    def fully_redundant(self):
        """Every parity matches the data on disk, so any single (RAID5) or
        double (RAID6) device loss is survivable.  Deliberately says nothing
        about records left behind: a stripe still listed in the log costs a
        future scrub, not redundancy, and folding that in here would make any
        policy that keeps its records look like it lost redundancy."""
        return all(self.par[k] == tuple(self.disk)
                   for k in range(self.nr_parity))


# --------------------------------------------------------------------------
# the write path
# --------------------------------------------------------------------------

# Does the read side of a read-modify-write consult the stale record before
# computing the new parity?  The fork does (mark_stale_sectors() in
# fs/btrfs/raid56.c); stock upstream has no record to consult.  It belongs on
# the WRITE path of this model because that is where it changes the outcome:
# an RMW that folds a stale sector into the new parity destroys the only copy
# of the acknowledged value before any scrub gets a chance to.
LEGACY_READ = False

# The refuted refinement, kept as a control: record the outcome only for a
# write the caller was told succeeded.  It sounds like the careful choice and
# is the opposite -- see policy_prove_or_preserve() and the comment in
# rmw_rbio().  Default False, i.e. the kernel's behaviour: record what the
# devices did, and judge proof later.
ONLY_CLAIM_ON_ACKED = False


def rmw_effective_disk(s):
    """What the read phase of an RMW hands to the parity computation.

    Reconstructed values for the columns the log says are stale, when the
    reconstruction fits the budget; the sector on disk otherwise.  Note that
    these values are NOT written back -- an RMW writes the sectors it was
    asked to write and the parity, nothing else -- so the column stays stale
    and the new parity keeps describing what was acknowledged.
    """
    eff = list(s.disk)
    if LEGACY_READ:
        return eff
    holes, good_par = stale_budget(s)
    if holes and len(holes) <= len(good_par):
        k = good_par[0]
        for d in holes:
            eff[d] = s.par[k][d]
    return eff


def rmw(st, cols, val, fail, require_parity):
    """One read-modify-write of @cols with value @val, with the device writes
    in @fail failing.  Returns a new Stripe, or None if the write is refused.

    @fail holds device indices: data columns and parity devices alike.
    A missing device is always a failed write.
    """
    s = st.copy()
    written = set(cols) | {s.nr_data + k for k in range(s.nr_parity)}
    fail = set(fail) | {d for d in written if s.missing[d]}
    if not fail <= written:
        return None

    # rbio_max_errors(): a write is acknowledged while the faults it took do
    # not exceed the profile's parity count.  This is a flat rule in the
    # kernel; no caller consults the log.
    if len(fail) > s.nr_parity:
        acked = False
    elif require_parity:
        # The de-rate under test for T1: require at least @require_parity of
        # the parity writes to land, so the stripe never ends up with every
        # parity stale at once.
        landed = sum(1 for k in range(s.nr_parity)
                     if s.nr_data + k not in fail)
        acked = landed >= require_parity
    else:
        acked = True

    # The parity a read-modify-write computes describes the values it INTENDED
    # to write, whether or not the data writes land.
    intended = rmw_effective_disk(s)
    for i in cols:
        intended[i] = val

    for i in cols:
        if i not in fail:
            s.disk[i] = val
    for k in range(s.nr_parity):
        if s.nr_data + k not in fail:
            s.par[k] = tuple(intended)

    if acked:
        for i in cols:
            s.committed[i] = val
    else:
        # A refused write leaves the caller knowing nothing landed; the
        # committed values are unchanged.  The stripe is still recorded,
        # because the disk may now be inconsistent.
        pass

    if fail:
        # The log records the blocks of the write.  This much is true however
        # the write ended: something touched this stripe and went wrong.
        s.sticky = s.sticky | frozenset(cols)
    if acked or not ONLY_CLAIM_ON_ACKED:
        # And separately, WHICH member each write left stale.  These fields
        # state what the DEVICES did; whether that amounts to proof is judged
        # later by the repair policy.  Recording only acknowledged writes
        # sounds more careful and is the opposite: a refused write whose
        # parity landed leaves that parity describing a vector nobody
        # committed, and unless the record says so the budget believes the
        # parity is usable and rebuilds live data out of it.  Set
        # --only-claim-on-acked and the misrepairs appear.
        if fail:
            s.stale = s.stale | frozenset(i for i in cols if i in fail)
            s.stale_par = s.stale_par | frozenset(
                k for k in range(s.nr_parity) if s.nr_data + k in fail)
        # A data write that lands clears any stale record for that column.
        s.stale = s.stale - frozenset(i for i in cols if i not in fail)
        s.stale_par = s.stale_par - frozenset(
            k for k in range(s.nr_parity) if s.nr_data + k not in fail)
    s.trace = s.trace + (("rmw", tuple(cols), val, tuple(sorted(fail)),
                          "ack" if acked else "EIO"),)
    return s


def unmount(st, persist_stale):
    """Cross a mount boundary.  sticky is on disk; stale is not, unless the
    format carries it (the T2 workaround)."""
    s = st.copy()
    if not persist_stale:
        s.stale = frozenset()
        s.stale_par = frozenset()
    s.trace = s.trace + (("mount",),)
    return s


def lose(st, d):
    s = st.copy()
    s.missing[d] = True
    s.trace = s.trace + (("lose", d),)
    return s


# --------------------------------------------------------------------------
# the scrub policies
# --------------------------------------------------------------------------
#
# Each returns a set of tags describing what it did, and mutates the stripe.
# "regen" means it rewrote every parity from the data on disk.

def _regen(s):
    if any(s.missing[s.nr_data + k] for k in range(s.nr_parity)):
        # Cannot rewrite a parity that is not there.
        return False
    s.par = [tuple(s.disk)] * s.nr_parity
    s.sticky = frozenset()
    s.stale = frozenset()
    s.stale_par = frozenset()
    return True


def _rebuild_missing_data(s):
    """What scrub does before touching parity: every data column that cannot
    be read straight off its device is reconstructed.  Returns False if some
    column could not be produced, which makes scrub abort before the parity
    ("unrepaired sectors detected")."""
    for i in range(s.nr_data):
        if s.missing[i]:
            # Nothing to write it back to.
            return False
        # Present and unchecksummed: trusted as it is.  This is
        # scrub_verify_one_sector()'s "we have no other choice but to trust
        # it", and it is where the data loss begins.
    return True


def policy_upstream(s):
    """Today's kernel.  Trust every readable data sector, recompute the
    parity from it."""
    tags = set()
    if not _rebuild_missing_data(s):
        return {"abort"}
    if _regen(s):
        tags.add("regen")
    return tags


def policy_refuse(s):
    """T3.  Any column the log has recorded is unverifiable, so decline to
    rewrite the parity and tell the user."""
    tags = set()
    if s.sticky:
        s.reported = True
        return {"refused"}
    if not _rebuild_missing_data(s):
        return {"abort"}
    if _regen(s):
        tags.add("regen")
    return tags


def policy_sticky_skip(s):
    """T2 with only the record that is actually persisted today.  sticky is a
    superset of stale, so skipping regeneration whenever it is set is sound
    but pays for stripes whose data was fine all along."""
    if s.sticky:
        s.reported = True
        return {"skipped"}
    if not _rebuild_missing_data(s):
        return {"abort"}
    return {"regen"} if _regen(s) else set()


def _stale_rebuild(s, avoid_stale_par):
    """T2 with the exact record.  A column the log says is stale is treated
    exactly as a checksum mismatch would be: reconstruct it from the parity,
    write it back, then recompute the parity from data now known good.

    @avoid_stale_par decides whether the reconstruction is allowed to use a
    parity that the log ALSO records as stale.  It is the whole difference
    between the two variants, and the model found the difference rather than
    the difference being designed in.
    """
    tags = set()
    if not _rebuild_missing_data(s):
        return {"abort"}
    for i in sorted(s.stale):
        if s.missing[i]:
            return {"skipped"}
        # Reconstruct column i as if its device had failed to read.
        v = s.recover(i, lost=(i,), avoid_stale_par=avoid_stale_par)
        if v is UNREADABLE or v == "garbage":
            # Nothing trustworthy left to reconstruct from.  Leave the stripe
            # exactly as it is and keep it recorded: the disk still holds a
            # value that was committed at some point, which is more than a
            # reconstruction from a parity known stale can promise.
            s.reported = True
            return {"skipped"}
        s.disk[i] = v
        tags.add("rebuilt")
    if _regen(s):
        tags.add("regen")
    return tags


def policy_stale_rebuild_naive(s):
    """Reconstructs from whichever parity comes first, as the read path does
    today.  Kept as a policy because it is what a straightforward reading of
    T2 produces, and the model's counterexample for it is the reason the
    parity-aware variant exists."""
    return _stale_rebuild(s, avoid_stale_par=False)


def policy_stale_rebuild(s):
    """T2, refusing to reconstruct from a parity the log records as stale."""
    return _stale_rebuild(s, avoid_stale_par=True)


def policy_prove_or_preserve(s):
    """What the kernel does now: repair what can be proved, preserve what
    cannot, never guess.

      - a column whose content carries its own proof (a checksum, or a metadata
        tree block) is left to the ordinary scrub path and never blocked;
      - a column the log NAMES -- recorded stale, which only an acknowledged
        write whose own data write failed can do -- is rebuilt from the parity
        and written back, and then the record is retired;
      - if the named columns outnumber the parities still usable, nothing is
        touched at all and the record is kept.

    The model has no notion of per-sector checksums, so this stands in for the
    unchecksummed case, which is the only one where the record decides
    anything.
    """
    if not _rebuild_missing_data(s):
        return {"abort"}
    holes, good_par = stale_budget(s)
    if not holes:
        # Nothing named.  Ordinary scrub, and the record has done its job.
        if _regen(s):
            return {"regen", "retired"}
        return set()
    if len(holes) > len(good_par) or any(s.missing[d] for d in holes):
        s.reported = True
        return {"preserved"}
    k = good_par[0]
    for d in holes:
        s.disk[d] = s.par[k][d]
    tags = {"rebuilt"}
    if _regen(s):
        tags.add("regen")
        tags.add("retired")
    return tags


def policy_stale_skip(s):
    """The smallest change to scrub that is still sound: if the log records
    any data column of this full stripe stale, leave the parity alone and keep
    the stripe recorded.

    It gives up the repair rather than arbitrating, so it cannot restore
    redundancy -- but it also cannot throw away the copy that still holds the
    acknowledged value, which is the whole defect.  Cheaper to implement than
    the rebuild: no write-back path, one early return.
    """
    if not _rebuild_missing_data(s):
        return {"abort"}
    if s.stale:
        s.reported = True
        return {"skipped"}
    if s.stale_par and s.nr_parity == 1:
        # The one parity does not describe the data.  Recomputing it from the
        # data is exactly the right repair here, so do not skip.
        pass
    return {"regen"} if _regen(s) else set()


def policy_stale_budgeted(s):
    """T2 under the budgeted rule -- the scrub half of read_stale_budgeted().

    Rebuild every stale column at once from the parities that are still
    trustworthy, then recompute the parity from data now known good.  When the
    budget does not cover the holes, do nothing at all and keep the stripe
    recorded: leaving a stale sector in place costs the acknowledged value
    only if the parity that still holds it is lost, whereas recomputing the
    parity from it throws that copy away immediately.
    """
    if not _rebuild_missing_data(s):
        return {"abort"}
    holes, good_par = stale_budget(s)
    if not holes:
        return {"regen"} if _regen(s) else set()
    if len(holes) > len(good_par) or any(s.missing[d] for d in holes):
        s.reported = True
        return {"skipped"}
    k = good_par[0]
    for d in holes:
        s.disk[d] = s.par[k][d]
    tags = {"rebuilt"}
    if _regen(s):
        tags.add("regen")
    return tags


def _delta(s, k):
    """The columns on which parity k disagrees with the disk.  In the real
    array this is a single byte; a single-element set is exactly the case
    where the byte ratio DQ/DP resolves to one in-range column index, and a
    larger set is where it does not (except by coincidence, which cannot help
    an algorithm that has to be right every time)."""
    return frozenset(i for i in range(s.nr_data) if s.par[k][i] != s.disk[i])


def policy_localise(s):
    """T1.  RAID6 only: when P and Q both disagree with the disk in a way that
    points at exactly one column j, conclude that column j is stale and
    rebuild it from the parity.

    This is the policy whose signature was called symmetric.  The model does
    not assume either way: it runs it and reports what happens.
    """
    if s.nr_parity != 2:
        return policy_upstream(s)
    if not _rebuild_missing_data(s):
        return {"abort"}
    if any(s.missing[s.nr_data + k] for k in range(2)):
        return policy_upstream(s)
    d0, d1 = _delta(s, 0), _delta(s, 1)
    # The real test is on bytes: dQ == g^j * dP for exactly one in-range j.
    # dP is the XOR of the per-column differences between P and the disk, dQ
    # the same weighted by g^i.  That resolves to a single in-range j exactly
    # when both parities differ from the disk on the same single column AND by
    # the same amount -- if P and Q disagree with each other at that column,
    # dQ/dP is g^j scaled by a second, unrelated ratio, and lands on a valid
    # column index only by coincidence.  An algorithm that has to be right
    # every time cannot bank on a coincidence, so the model does not let it.
    if d0 == d1 and len(d0) == 1 and s.par[0][next(iter(d0))] == s.par[1][next(iter(d0))]:
        j = next(iter(d0))
        s.disk[j] = s.par[0][j]
        tags = {"localised"}
        if _regen(s):
            tags.add("regen")
        return tags
    return policy_upstream(s)


def policy_localise_derate(s):
    """T1 with the write-side condition that makes it decidable: see
    --require-parity.  The policy code is identical; what changes is that the
    histories reaching it can never have left every parity stale at once."""
    return policy_localise(s)


def policy_refuse_replace_safe(s):
    """T3 with its device-replace hole closed: still produce content for the
    replacement device, only decline to rewrite the parity."""
    if s.sticky:
        s.reported = True
        # The replacement device is filled from whatever the stripe can
        # supply, exactly as a read would.
        return {"refused", "replaced"}
    if not _rebuild_missing_data(s):
        return {"abort"}
    return {"regen"} if _regen(s) else set()


POLICIES = {
    "upstream": policy_upstream,
    "refuse": policy_refuse,
    "refuse-replace-safe": policy_refuse_replace_safe,
    "sticky-skip": policy_sticky_skip,
    "stale-rebuild": policy_stale_rebuild,
    "stale-rebuild-naive": policy_stale_rebuild_naive,
    "stale-budgeted": policy_stale_budgeted,
    "stale-skip": policy_stale_skip,
    "prove-or-preserve": policy_prove_or_preserve,
    "localise": policy_localise,
    "localise-derate": policy_localise_derate,
}

# Policies that need the stale record to have survived the mount boundary.
NEEDS_PERSIST = {"stale-rebuild", "stale-rebuild-naive", "stale-budgeted",
                 "stale-skip", "prove-or-preserve"}
# Policies that only mean anything with two parities.
NEEDS_RAID6 = {"localise", "localise-derate"}



# --------------------------------------------------------------------------
# the read path
# --------------------------------------------------------------------------
#
# Separate question from the scrub, same state space.  verify_bio_data_sectors()
# forces a reconstruction for every sector the log records as stale, because
# for nodatacow data that record is the only thing that knows the sector on
# disk is not what was acknowledged.  What does that reconstruction come from?

def read_plain(s, i):
    """Upstream: no record, so the sector on disk is returned as it is."""
    return s.disk[i]


def read_stale_any(s, i):
    """The shipped behaviour: a sector recorded stale is treated as a read
    error, and the reconstruction uses whatever parity is present."""
    if i in s.stale:
        return s.recover(i, lost=(i,))
    return s.disk[i]


# Recording WHICH parity a failed write left stale costs a second bitmap in
# every log entry.  Recording only "some parity of this full stripe is stale"
# costs one bit and is still sound -- it just gives up the rebuild whenever
# any parity is suspect, instead of falling back to the other one.  Which of
# those to put on disk is a real trade-off, so it is a switch and the model
# measures the difference rather than the choice being asserted.
CONSERVATIVE_PARITY = False


def stale_budget(s):
    """The two numbers the budgeted rule needs, both readable straight out of
    the log and the chunk map -- no oracle, no checksum, nothing the kernel
    does not already have at the point of the decision.

    holes     every data column that cannot be believed: recorded stale, or
              on a device that is not there
    good_par  parity devices that are present and NOT recorded stale
    """
    if CONSERVATIVE_PARITY and s.stale_par:
        good_par = []
    else:
        good_par = [k for k in range(s.nr_parity)
                    if s.present(s.nr_data + k) and k not in s.stale_par]
    holes = sorted({d for d in range(s.nr_data)
                    if d in s.stale or not s.present(d)})
    return holes, good_par


def read_stale_budgeted(s, i):
    """The rule this model exists to justify.

    Three differences from the shipped behaviour, each one a counterexample
    the model produced:

      1. ALL stale columns of the full stripe are holes, not just the sector
         being read.  A parity describes the whole stripe; reconstructing one
         column while another column it was computed from is also stale gives
         a value nothing ever committed.
      2. A parity the log records as stale is not a source.  It describes an
         older data vector, so rebuilding from it undoes an acknowledged
         write just as surely as recomputing parity from a stale sector does.
      3. When the holes outnumber the usable parities the record cannot be
         acted on at all, and the answer is the sector on disk -- exactly
         what upstream returns.  That is the property that makes this safe to
         turn on: where it cannot help it does nothing, so it is never worse
         than the code it replaces.
    """
    holes, good_par = stale_budget(s)
    if i not in holes:
        return s.disk[i]
    if len(holes) > len(good_par):
        return s.disk[i]
    k = good_par[0]
    return s.par[k][i]


READERS = {
    "plain": read_plain,
    "stale-any": read_stale_any,
    "stale-budgeted": read_stale_budgeted,
}


def judge_read(st, reader_name, persist_stale):
    """Does this reader ever hand back a value that was never committed, in a
    state where the upstream reader would have handed back the committed one?
    """
    reader = READERS[reader_name]
    pre = unmount(st, persist_stale)
    for i in range(pre.nr_data):
        if pre.missing[i]:
            continue
        got = reader(pre, i)
        if got == pre.committed[i]:
            continue
        # The reader is wrong here.  Is it wrong where upstream was right?
        if read_plain(pre, i) == pre.committed[i]:
            return ("READREGRESS", reader_name, st.trace, describe(pre),
                    "column %d: %s returned %r, plain would have returned %r"
                    % (i, reader_name, got, read_plain(pre, i)))
    return None


def judge_read_miss(st, reader_name, persist_stale):
    """The other direction: upstream hands back a stale value and this reader
    recovers the committed one.  That is the whole point of the record, so
    count it as the benefit against which any regression is weighed."""
    reader = READERS[reader_name]
    pre = unmount(st, persist_stale)
    n = 0
    for i in range(pre.nr_data):
        if pre.missing[i]:
            continue
        if read_plain(pre, i) != pre.committed[i] and reader(pre, i) == pre.committed[i]:
            n += 1
    return n


# --------------------------------------------------------------------------
# search
# --------------------------------------------------------------------------

def successors(st, nr_vals, allow_lose, require_parity, in_place_cols):
    """Every next operation from @st."""
    n, p = st.nr_data, st.nr_parity
    val = 100 + len(st.trace)
    for r in range(1, in_place_cols + 1):
        for cols in itertools.combinations(range(n), r):
            written = list(cols) + [n + k for k in range(p)]
            live = [d for d in written if not st.missing[d]]
            # Every subset of the live writes may fail, up to the profile's
            # tolerance plus one (one past the edge, so the model can see a
            # refused write as well as an accepted one).
            for nf in range(0, min(len(live), p + 1) + 1):
                for fail in itertools.combinations(live, nf):
                    nxt = rmw(st, cols, val, fail, require_parity)
                    if nxt is not None:
                        yield nxt
    if allow_lose:
        for d in range(n + p):
            if not st.missing[d]:
                yield lose(st, d)


def explore(nr_data, nr_parity, depth, policy_name, persist_stale,
            require_parity, allow_lose, in_place_cols, replacing,
            reader=None):
    policy = POLICIES[policy_name] if policy_name else None
    start = Stripe(nr_data, nr_parity, replacing)
    seen = {start.key()}
    frontier = [start]
    findings = []
    nr_states = 0

    for _ in range(depth):
        nxt = []
        for st in frontier:
            for s in successors(st, depth, allow_lose, require_parity,
                                in_place_cols):
                k = s.key()
                if k in seen:
                    continue
                seen.add(k)
                nxt.append(s)
                nr_states += 1
                if reader:
                    f = judge_read(s, reader, persist_stale)
                    if f:
                        findings.append(f)
                    n = judge_read_miss(s, reader, persist_stale)
                    if n:
                        findings.append(("RECOVERED", reader, s.trace,
                                         describe(s), "%d column(s)" % n))
                else:
                    f = judge(s, policy, policy_name, persist_stale)
                    if f:
                        findings.append(f)
        frontier = nxt
        if not frontier:
            break
    return findings, nr_states


def judge(st, policy, policy_name, persist_stale):
    """Run the scrub on a copy of @st and classify the outcome."""
    # A scrub always happens after a mount in the reproduction that matters;
    # crossing the boundary is what loses the unpersisted record.
    pre = unmount(st, persist_stale)
    before = pre.recoverable_now()
    before_redundant = pre.fully_redundant()

    post = pre.copy()
    tags = policy(post)
    after = post.recoverable_now()

    # DESTROY: something the stripe could still supply before the scrub, it
    # cannot supply after.
    if before and not after:
        return ("DESTROY", policy_name, st.trace, describe(pre), describe(post))
    if () in before and () not in after:
        return ("DESTROY", policy_name, st.trace, describe(pre), describe(post))

    # MISREPAIR: a value on a data device that was never committed there.
    for i in range(post.nr_data):
        if post.missing[i]:
            continue
        if post.disk[i] != pre.disk[i] and post.disk[i] != post.committed[i]:
            return ("MISREPAIR", policy_name, st.trace, describe(pre),
                    describe(post))

    # NOREPAIR: upstream would have restored full redundancy here and this
    # policy did not.  Only counted when the stripe was healthy enough for
    # upstream to be right, i.e. nothing was actually stale.
    if not pre.stale and not pre.stale_par and not any(pre.missing):
        up = pre.copy()
        policy_upstream(up)
        if up.fully_redundant() and not post.fully_redundant():
            return ("NOREPAIR", policy_name, st.trace, describe(pre),
                    describe(post))

    # UNREPAIRED: the strongest SOUND policy would have left this stripe
    # fully redundant and this one did not.  NOREPAIR above only catches
    # declining to act where nothing was wrong; this catches declining to act
    # where something was wrong and was fixable, which is the entire price of
    # the cheaper policies and is invisible without it.
    if not post.fully_redundant():
        ref = pre.copy()
        policy_stale_rebuild(ref)
        if ref.fully_redundant():
            return ("UNREPAIRED", policy_name, st.trace, describe(pre),
                    describe(post))

    # REPLHOLE: a replace was running and the policy declined to write.
    if pre.replacing is not None and "refused" in tags and "replaced" not in tags:
        return ("REPLHOLE", policy_name, st.trace, describe(pre), describe(post))
    return None


def describe(s):
    return ("disk=%s committed=%s par=%s missing=%s sticky=%s stale=%s stale_par=%s"
            % (s.disk, s.committed, [list(p) for p in s.par],
               [i for i, m in enumerate(s.missing) if m],
               sorted(s.sticky), sorted(s.stale), sorted(s.stale_par)))


def fmt_trace(tr):
    out = []
    for op in tr:
        if op[0] == "rmw":
            out.append("rmw cols=%s val=%s failed_devs=%s -> %s"
                       % (list(op[1]), op[2], list(op[3]), op[4]))
        elif op[0] == "lose":
            out.append("lose dev%d" % op[1])
        else:
            out.append("mount")
    return " ; ".join(out)


# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", type=int, default=3)
    ap.add_argument("--parity", type=int, default=1)
    ap.add_argument("--depth", type=int, default=3)
    ap.add_argument("--policy", default="upstream", choices=sorted(POLICIES))
    ap.add_argument("--persist-stale", action="store_true",
                    help="the stale record survives a mount (the T2 workaround)")
    ap.add_argument("--require-parity", type=int, default=0,
                    help="refuse an RMW unless at least N parity writes land "
                         "(the T1 workaround); 0 disables")
    ap.add_argument("--lose", action="store_true",
                    help="let devices go missing as well")
    ap.add_argument("--in-place-cols", type=int, default=2,
                    help="largest number of columns one write may touch")
    ap.add_argument("--replacing", type=int, default=None,
                    help="device index under replace")
    ap.add_argument("--max-report", type=int, default=3)
    ap.add_argument("--only-claim-on-acked", action="store_true",
                    help="record the outcome only for an acknowledged write "
                         "(a refuted refinement, kept as a control)")
    ap.add_argument("--legacy-read", action="store_true",
                    help="the read phase of an RMW ignores the stale record, "
                         "as stock upstream does")
    ap.add_argument("--conservative-parity", action="store_true",
                    help="record only THAT some parity is stale, not which")
    ap.add_argument("--reader", choices=sorted(READERS),
                    help="model the READ path with this reader instead of a "
                         "scrub policy")
    ap.add_argument("--all-readers", action="store_true",
                    help="run every reader and print a comparison table")
    ap.add_argument("--all", action="store_true",
                    help="run every policy and print a comparison table")
    ap.add_argument("--self-check", action="store_true",
                    help="fail unless the upstream policy reproduces DESTROY")
    args = ap.parse_args()
    global CONSERVATIVE_PARITY, LEGACY_READ, ONLY_CLAIM_ON_ACKED
    CONSERVATIVE_PARITY = args.conservative_parity
    LEGACY_READ = args.legacy_read
    ONLY_CLAIM_ON_ACKED = args.only_claim_on_acked

    if args.all_readers:
        return run_all_readers(args)
    if args.all:
        return run_all(args)

    findings, nr = explore(args.data, args.parity, args.depth, args.policy,
                           args.persist_stale, args.require_parity,
                           args.lose, args.in_place_cols, args.replacing,
                           reader=args.reader)
    report(args, findings, nr)
    if args.self_check and args.policy == "upstream":
        if not any(f[0] == "DESTROY" for f in findings):
            print("SELF-CHECK FAILED: upstream did not reproduce DESTROY; "
                  "the model is not exercising the bug", file=sys.stderr)
            return 2
    return 1 if any(f[0] in ("DESTROY", "MISREPAIR") for f in findings) else 0


def report(args, findings, nr):
    kinds = {}
    for f in findings:
        kinds.setdefault(f[0], []).append(f)
    print("policy=%s data=%d parity=%d depth=%d persist_stale=%s "
          "require_parity=%d lose=%s replacing=%s"
          % (args.policy, args.data, args.parity, args.depth,
             args.persist_stale, args.require_parity, args.lose,
             args.replacing))
    print("%d states examined" % nr)
    for kind in ("MISREPAIR", "DESTROY", "NOREPAIR", "UNREPAIRED", "REPLHOLE",
                 "READREGRESS", "RECOVERED"):
        got = kinds.get(kind, [])
        print("  %-10s %d" % (kind, len(got)))
        for f in got[:args.max_report]:
            print("      history: %s" % fmt_trace(f[2]))
            print("      before : %s" % f[3])
            print("      after  : %s" % f[4])


def run_all_readers(args):
    rows = []
    for name in sorted(READERS):
        persist = True     # the read path only ever sees an in-memory record
        findings, nr = explore(args.data, args.parity, args.depth, None,
                               persist, args.require_parity, args.lose,
                               args.in_place_cols, args.replacing,
                               reader=name)
        reg = [f for f in findings if f[0] == "READREGRESS"]
        rec = [f for f in findings if f[0] == "RECOVERED"]
        rows.append((name, nr, len(reg), len(rec), reg[0] if reg else None))

    print("READ PATH   data=%d parity=%d depth=%d lose=%s"
          % (args.data, args.parity, args.depth, args.lose))
    print()
    print("%-22s %8s %13s %11s" % ("reader", "states", "READREGRESS",
                                   "RECOVERED"))
    for name, nr, reg, rec, _ in rows:
        print("%-22s %8d %13d %11d" % (name, nr, reg, rec))
    print()
    for name, _, _, _, f in rows:
        if f:
            print("%s / READREGRESS" % name)
            print("  history: %s" % fmt_trace(f[2]))
            print("  state  : %s" % f[3])
            print("  %s" % f[4])
            print()
    plain = [r for r in rows if r[0] == "plain"]
    if plain and plain[0][2] != 0:
        print("SELF-CHECK FAILED: the plain reader cannot regress against "
              "itself", file=sys.stderr)
        return 2
    return 0


def run_all(args):
    rows = []
    for name in sorted(POLICIES):
        if name in NEEDS_RAID6 and args.parity != 2:
            continue
        persist = args.persist_stale or name in NEEDS_PERSIST
        req = args.require_parity
        if name == "localise-derate":
            # This variant is defined by its write-side condition.
            req = max(req, 1)
        findings, nr = explore(args.data, args.parity, args.depth, name,
                               persist, req, args.lose, args.in_place_cols,
                               args.replacing)
        c = {k: 0 for k in ("DESTROY", "MISREPAIR", "NOREPAIR", "UNREPAIRED",
                            "REPLHOLE")}
        first = {}
        for f in findings:
            c[f[0]] += 1
            first.setdefault(f[0], f)
        rows.append((name, persist, req, nr, c, first))

    print("data=%d parity=%d depth=%d lose=%s replacing=%s in_place_cols=%d"
          % (args.data, args.parity, args.depth, args.lose, args.replacing,
             args.in_place_cols))
    print()
    print("%-22s %-8s %-6s %8s %9s %10s %9s %11s %9s"
          % ("policy", "persist", "reqpar", "states", "MISREPAIR", "DESTROY",
             "NOREPAIR", "UNREPAIRED", "REPLHOLE"))
    for name, persist, req, nr, c, _ in rows:
        print("%-22s %-8s %-6d %8d %9d %10d %9d %11d %9d"
              % (name, persist, req, nr, c["MISREPAIR"], c["DESTROY"],
                 c["NOREPAIR"], c["UNREPAIRED"], c["REPLHOLE"]))
    print()
    for name, _, _, _, c, first in rows:
        for kind in ("MISREPAIR", "DESTROY"):
            if kind in first:
                f = first[kind]
                print("%s / %s" % (name, kind))
                print("  history: %s" % fmt_trace(f[2]))
                print("  before : %s" % f[3])
                print("  after  : %s" % f[4])
                print()
    up = [r for r in rows if r[0] == "upstream"]
    if up and up[0][4]["DESTROY"] == 0:
        print("SELF-CHECK FAILED: upstream did not reproduce DESTROY",
              file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
