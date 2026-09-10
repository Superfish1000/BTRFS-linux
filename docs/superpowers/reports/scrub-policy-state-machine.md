# What a scrub may do to an unchecksummed RAID5/6 stripe

Three fixes were proposed for "plain `btrfs scrub` destroys nodatacow data
that was still recoverable", and all three were withdrawn on an argument
rather than a measurement. `tools/testing/btrfs/scrub_policy_model.py`
enumerates every write history to a bounded depth, applies each candidate
policy, and reports what each one actually does.

Negative control: the `upstream` policy must reproduce DESTROY, since that is
the defect measured under UML at 8 of 32 acknowledged blocks. It does, on the
first state it reaches — a single acknowledged write whose data device took the
error:

```
rmw cols=[0] val=100 failed_devs=[0] -> ack
before : disk=[0,1,2] committed=[100,1,2] par=[[100,1,2]]
after  : disk=[0,1,2] committed=[100,1,2] par=[[0,1,2]]
```

`--self-check` fails the program if it ever stops reproducing it.

## The four measures

| | meaning |
|---|---|
| DESTROY | a committed value recoverable before the scrub is not recoverable after |
| MISREPAIR | the scrub wrote a value onto a data device that was never committed there |
| NOREPAIR | declined to act where nothing was wrong |
| UNREPAIRED | declined to act where something was wrong and was fixable |

## Result, depth 3, three data columns

RAID5 (8386 states) / RAID6 (41791 states), with the fork's stale-aware read
path modelled on the write side:

| policy | MISREPAIR | DESTROY | NOREPAIR | UNREPAIRED |
|---|---|---|---|---|
| upstream | 0 / 0 | **1488 / 6291** | 0 / 0 | 0 / 0 |
| localise (T1) | – / **147** | – / 5145 | 0 / 0 | 0 / 0 |
| localise-derate (T1 + workaround) | – / **75** | – / 5043 | 0 / 0 | 0 / 0 |
| refuse (T3) | 0 / 0 | 0 / 0 | **7317 / 40707** | 0 / 0 |
| sticky-skip | 0 / 0 | 0 / 0 | **7317 / 40707** | 0 / 0 |
| stale-rebuild-naive | **3 / 561** | **36 / 154** | 0 / 0 | 0 / 3741 |
| **stale-skip** | 0 / 0 | 0 / 0 | 0 / 0 | 973 / 9705 |
| **stale-budgeted** | 0 / 0 | 0 / 0 | 0 / 0 | 259 / 2718 |
| stale-rebuild | 0 / 0 | 0 / 0 | 0 / 0 | reference |

With device losses included as well (`--lose`), the state count rises to
14569 and 67765 and the conclusions do not move: `stale-skip` and
`stale-budgeted` stay at 0 MISREPAIR and 0 DESTROY, `upstream` stays at 1488
and 6291 destroyed, and `localise` stays at 147 misrepairs.

## T1 — RAID6 P/Q localisation: dead, and now measured

The signature is symmetric. "Data column j is stale, both parities fresh" and
"data column j is fresh, both parities stale from an update to j" produce
*identical* deltas: both parities disagree with the disk at exactly j, by
exactly the same amount. The two need opposite repairs.

The workaround tried: require at least one parity write to land before
acknowledging an RMW, so the stripe can never end up with every parity stale.
**It does not work, and the model says why** — refusing a write does not undo
the parity divergence it already caused. The devices were still not written.
75 misrepairs survive at RAID6 depth 3, and a misrepair is worse than the bug
it was meant to fix, because it puts a never-committed value on a data device.

```
rmw cols=[0] val=100 failed_devs=[0]    -> ack
rmw cols=[1] val=101 failed_devs=[]     -> ack
rmw cols=[0] val=102 failed_devs=[3,4]  -> EIO      <- both parity writes lost
before : disk=[102,101,2] committed=[100,101,2] par=[[0,101,2],[0,101,2]]
after  : disk=[0,101,2]                                    <- wrote 0, never committed
```

## T3 — refuse and report: sound, dominated

0 DESTROY, but it declines to restore redundancy in 7317 of 8386 RAID5 states.
Its device-replace hole is real and closable: with `--replacing 0`, `refuse`
scores REPLHOLE 1195 and `refuse-replace-safe` scores 0. Not worth pursuing
while T2 exists.

## T2 — consult the log's stale record: the one that works

Clean on every axis, at both parities and every width tried. Its original
objection — the record is not persisted, and the reproduction crosses a mount
— is a coverage problem, not a soundness one, and the workaround is to persist
it.

But only in the right form. `stale-rebuild-naive`, which is what a
straightforward reading of T2 produces, is **not** clean: 561 misrepairs at
RAID6. Three refinements are load-bearing, and the model produced each one as
a counterexample rather than them being designed in:

1. every stale column of the **full stripe** is a hole, not just the sector
   being read;
2. a parity the log records stale is not a source;
3. when the holes outnumber the usable parities, do nothing — which is
   upstream's behaviour, so the record is never worse than not having it.

## The read path had the same defect, and it was shipped

The same model, run over readers rather than scrub policies
(`--all-readers`), says the read-path hook as shipped regresses in **6835 of
14446** RAID5 states and **26148 of 64978** RAID6 states: it hands back a
value nothing ever committed where a plain upstream read returns the committed
one. The budgeted rule is 0 in both, while still recovering 6180 RAID6 columns
that upstream gets wrong.

Encoding choice, measured rather than asserted: recording *which* parity is
stale rather than only *that* one is, costs a second bitmap and is identical
on RAID5 (one parity, one bit). On RAID6 the conservative single bit recovers
2166 columns against 6180 — it gives up 65% of the benefit. Worth the bitmap.
