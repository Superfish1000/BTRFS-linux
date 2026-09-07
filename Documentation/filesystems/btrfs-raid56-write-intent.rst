.. SPDX-License-Identifier: GPL-2.0

=============================
BTRFS RAID56 write-intent log
=============================

The RAID5/6 write hole
======================

A write that does not cover a whole RAID5/6 full stripe is a
read-modify-write (RMW): btrfs reads the full stripe, computes the new P/Q
sectors and writes the new data sectors and the new P/Q sectors as
independent requests to independent devices.  If the system crashes after
some of these requests reached their device and others did not, the affected
vertical stripes are inconsistent: the parity does not match the data.

The new data itself is not at risk.  btrfs is copy-on-write, so the sectors
being written were free space and the transaction that would reference them
never committed.  The problem is the *other* sectors of the same vertical
stripes, which belong to committed extents: their content on disk is intact
but their redundancy is gone.  If the device holding one of them fails or
returns a bad sector, reconstruction from the stale parity produces garbage.
With data checksums this is detected as an unrecoverable checksum error; for
``nodatasum`` data it is silent corruption.

Writes that go in place (``nodatacow`` files, preallocated extents) are
affected even when they cover a full stripe: the sectors being overwritten
are referenced.

Before this feature btrfs had nothing to close this window.

The fix
=======

Every writable device carries a small log (two 4KiB blocks at physical
offset 512KiB, inside the first megabyte that btrfs reserves on every device)
listing the full stripes that have such a write in flight, with 64KiB
granularity of the logical address space.  Each listed stripe is either a
plain record (a write in flight on a working array) or an error record (see
below).

Runtime protocol
----------------

1. Before a sub-stripe RMW (or an in-place write) submits any write, the full
   stripe is added to the in-memory set and a block listing the union of the
   previous block and the set is written to every writable device with FUA.
   The write proceeds only after that log write completed on enough devices
   to survive the number of device failures the RAID profile tolerates;
   otherwise it fails with EIO before touching the stripe.  Concurrent RMWs
   share one log write.  Because the block only adds to the previous one, no
   device cache has to be flushed for it.
2. When all writes of the RMW have completed, the stripe leaves the in-memory
   set.  The on-disk log drops it at the next transaction or log commit: the
   set is snapshotted before the commit's device barriers, every device is
   asked to flush its cache, and only if every device confirmed are the
   stripes that had finished before the snapshot dropped, so their data and
   parity writes are on stable media before the log stops mentioning them
   (a stripe finishing during the flush stays listed).  If a device did not
   confirm, nothing is dropped and the finished stripes become error records
   (that device may hold stale sectors).  A log write that finds the union
   too large for a block flushes the devices itself and drops the finished
   stripes in the same way.
3. Each device alternates between its two blocks and only moves on after a
   successful write, so the block being overwritten on a device is never its
   newest valid one.  A torn log write can only invalidate the newest block;
   the previous one is still valid and, by the two rules above, lists every
   stripe whose writes can be unflushed on that device.
4. A RMW whose writes hit a device error (or a missing device) leaves the
   stripe inconsistent on that device without any crash.  Such a stripe is
   kept in the log as an error record so that it is scrubbed at the next
   mount, once the device is back, replaced or dropped.  A full stripe write
   that a device did not take is recorded the same way.  Error records are
   evicted, with a warning, only when the log is full; ``btrfs scrub`` covers
   them then.
5. A log write is allowed to fail on some devices: a device that did not
   receive the new block keeps the previous one, which lists a superset of
   the stripes it may hold unflushed.  Only the write that records a new
   stripe has to reach enough devices, see 1.

Full stripe copy-on-write writes need no record: every sector of the stripe
is unreferenced until the transaction referencing it commits, which happens
only after all those writes completed and were flushed by the commit's device
barriers.

Recovery
--------

At mount, before anything else is written (this includes a read-only mount
that has a tree log to replay, since the replay writes), the log blocks of
all present devices are read.  Per device the newest valid block counts
(valid = correct magic, this filesystem's uuid, correct checksum): a block
with sequence number N was written to that device with a flush whenever it
dropped a stripe listed by N-1, so what N no longer lists is on stable media
on that device.  Across devices the union is taken: a device that missed a
commit (torn write, I/O error, absent at the time) still lists the stripes
that commit dropped.

Every listed full stripe is then scrubbed (``btrfs_scrub_raid56_full_stripe()``
in ``fs/btrfs/scrub.c``): every sector holding an extent is verified (data
checksums, tree block headers for metadata), bad sectors are rebuilt from the
existing parity and written back to their device, and P/Q are recomputed from
the verified data for the vertical stripes that hold extents.  If a sector
cannot be repaired the parity of that full stripe is left alone: recomputing
it from unverified sectors would turn a still recoverable stripe into
consistent garbage.

For a plain record on a fully present array, every device holds what was
last written to it, so after that verification the parity of *every*
vertical stripe is recomputed from the data on disk.  This also covers
extents that are only referenced from the tree log at that point (fsync'ed
data and the log tree blocks themselves): they are not in the extent tree
until the log has been replayed, and a crash in the middle of a RMW to the
same vertical stripe leaves them without valid parity otherwise.

For an error record only verified sectors are trusted.  While a tree log is
still to be replayed (so that extents may be hidden from the verification)
the sectors holding extents are verified and repaired but no parity is
written at all: the scrub recomputes the parity of a vertical stripe from
every sector in it, including ones it cannot verify, which could destroy
the parity an extent hidden in the log still needs.  After the tree log has
been replayed the remaining error records are scrubbed again with every
extent visible, their parity regenerated, and they are dropped when the
stripe is fully consistent.  A stripe with a device missing, or with a
sector that could not be repaired, stays recorded and is scrubbed again at
the first mount with the device back or replaced.

Scrubbing a consistent stripe is a no-op, so stale entries (from an old
device that re-joined the filesystem, or from the older of the two blocks)
are harmless.

Feature flag and enabling
-------------------------

The log is tied to the ``compat_ro`` feature flag
``BTRFS_FEATURE_COMPAT_RO_RAID56_WRITE_INTENT`` (bit 4): a kernel that does not
maintain the log must not write to the filesystem, otherwise the log would be
stale after a crash.  Kernels without support therefore mount such a
filesystem read-only, and ``btrfs check --repair`` of a btrfs-progs without
support refuses to open it read-write.

The flag is set automatically at the first read-write mount of a filesystem
that has RAID5/6 block groups (``BTRFS_FEATURE_INCOMPAT_RAID56``), and by the
transaction that creates the first RAID5/6 chunk of a filesystem that had
none (for example ``btrfs balance -dconvert=raid5``), whose commit starts the
log before it writes the superblock.  A message is printed when this
happens.  To opt out, mount with ``-o noraid56_write_intent``; this only
prevents the automatic enabling, a filesystem that already has the flag
keeps its log maintained.

The flag can also be set or cleared on a mounted filesystem through sysfs
(or ``BTRFS_IOC_SET_FEATURES``)::

    echo 1 > /sys/fs/btrfs/<uuid>/features/raid56_write_intent
    echo 0 > /sys/fs/btrfs/<uuid>/features/raid56_write_intent

Setting it persists everything that is in flight before the flag is written.
Clearing it keeps the log maintained until a superblock without the flag is
durable (the commit after the one that writes it), so that a crash in
between is still recovered by a kernel that sees the flag; later RAID5/6
chunks do not turn it back on, the next read-write mount does unless the
mount option is given.

Statistics are exported in ``/sys/fs/btrfs/<uuid>/raid56_write_intent``.

Cost
----

A sub-stripe RMW pays one 4KiB FUA write per device (batched across
concurrent RMWs) before its own writes.  A transaction or log commit pays one
4KiB write per device after the barriers it issues anyway, only if the
in-flight set changed since the last log write.  Recovery reads
and rewrites the parity of at most as many full stripes as were in flight at
the crash.  The log holds 165 regions of 4MiB; a RMW that finds it full waits
for in-flight RMWs to finish.

Limits
======

* A device already missing when the crash happens, or a device that failed
  a write to the stripe shortly before it: a vertical stripe whose missing
  or stale sector is referenced data and whose parity was being updated by
  the crashed write has two faults, beyond what RAID5 (one) tolerates, and
  cannot be reconstructed.  The rebuild is verified against the data
  checksum (or the tree block header), so this is a detected loss, not
  silent corruption, except for ``nodatasum`` data.  If the lost block is a
  tree log block the mount fails with an I/O error at the log replay, as it
  does today, and ``btrfs rescue zero-log`` discards the log.  Closing this
  case needs a journal of the data itself, which the log does not provide.
* ``nobarrier``: the log writes are issued without FUA/PREFLUSH like every
  other write, and the guarantee is only as good as the device's volatile
  cache ordering.
* Zoned devices are not supported (RAID5/6 is not supported on them either).
* A device that acknowledges a flush and loses the data anyway is outside
  what any of this can protect against.

Failure points
==============

Every point at which the protocol can be interrupted, and what happens:

========================================  ========================================================
Failure                                   Outcome
========================================  ========================================================
Crash before the log write                No stripe write was issued; nothing to recover.
Crash during the log write (torn block)   Same; the older block stays valid, RMW never started.
Log write I/O error, enough copies left   RMW proceeds; the failing device keeps its older block,
                                          which lists a superset, and counts an error.
Log write I/O error, too few copies       RMW fails with EIO before writing, no inconsistency.
Log full                                  RMW waits for in-flight ones; error records evicted.
Crash after some data/parity writes       Stripe listed; scrubbed and parity regenerated at mount.
Torn data or parity sector                Same; the regeneration reads what is on disk.
Write error on a data or parity device    Stripe stays listed (error record) until scrubbed.
Device pulled during writes               As above; scrubbed once it is back or replaced.
Crash after all writes, before the clear  Stripe listed; the scrub is a no-op.
Crash during the clear (torn block)       Older block valid, same as above.
Clear write I/O error                     Device keeps the older block, which lists a superset.
Flush not confirmed by a device at commit Nothing is dropped; the finished stripes are kept as
                                          error records until a later commit's flush succeeds
                                          everywhere or the next mount scrubs them.
Crash during the recovery itself          Log still lists the stripe; redone at the next mount.
Unreadable or stale sector at recovery    Rebuilt from parity and verified by checksum, written
                                          back; if unrepairable the parity is left alone and
                                          the stripe stays recorded.
Parity write fails during recovery        Stripe stays recorded (even within RAID tolerance).
Repair write-back fails during recovery   Same.
Unreadable sector without extent          Parity of that vertical stripe left alone (after the
                                          log replay, if any); the record is dropped.
Device missing at recovery                Missing sectors rebuilt and verified; parity written
                                          to the present devices; the stripe stays recorded and
                                          is scrubbed again once the device is back or replaced,
                                          so its stale sectors get repaired.
Extent only in the tree log at recovery   Plain record: parity of every vertical stripe
                                          regenerated, covers it.  Error record: scrubbed again
                                          after the log replay.
Crash during a tree log replay            The replay's own writes are logged (also on a
                                          read-only mount); recovered at the next mount.
Log block unreadable on a device          Device skipped, the others provide the log.
Recovery of a stripe fails otherwise      (corrupt extent tree leaf, ...) The stripe stays
                                          recorded, the mount proceeds; only a memory
                                          allocation failure fails the mount.
Write recorded during the commit's flush  Listed in the snapshot the commit drops against, so
                                          it stays listed until the next commit's flush.
Read-only mount without a dirty log       Nothing written; recovery runs at remount read-write.
Read-only media (all devices read-only)   Nothing written; a dirty tree log fails the mount as
                                          before.
Device add/remove/replace during writes   Log writer never takes the device list mutex; it
                                          holds a reference on each block device it writes.
RAID5/6 chunk created at runtime          Log enabled by the transaction that creates the chunk,
                                          before its superblock is written.
Conversion away from RAID5/6              Log stays enabled and harmless.
Feature flag cleared through sysfs        Log maintained until the superblock without the flag
                                          is durable.
In-place (nodatacow/prealloc) write       Recorded even when it covers the full stripe.
Older kernel                              Mounts read-only (compat_ro flag).
Degraded before the crash                 Documented limit: detected, not silent (see above).
========================================  ========================================================

Verification
============

* ``tools/testing/btrfs/raid56_write_hole_model.py`` is an exhaustive state
  machine model of one vertical stripe under RMW: every combination of
  completed/lost/torn data and parity writes at the crash, every crash point
  of the protocol, and every loss of up to one (RAID5) or two (RAID6) devices
  afterwards.  It shows the loss of committed data without the log and none
  with it, for two to five data stripes.
* ``tools/testing/btrfs/raid56_wib_log_model.py`` is an exhaustive model of
  the on-disk protocol: log writes and flushes that fail per device, torn
  log writes at the crash, and device loss after it.  It shows that every
  stripe with unflushed or stale data on a surviving device is listed in the
  newest valid block of a surviving device, and that weakening the protocol
  (taking the set to write after the flush, not adding later log writes to
  the commit's snapshot, or dropping without a confirmed flush) breaks
  that.
* ``fs/btrfs/tests/raid56-wib-tests.c`` unit tests the in-memory tracking,
  the block encoding, torn/foreign block rejection, the recovery list merge,
  the log-full handling and the enable/disable ordering
  (``CONFIG_BTRFS_FS_RUN_SANITY_TESTS``).
* With ``CONFIG_BTRFS_DEBUG`` the module parameter
  ``btrfs.raid56_crash_point`` injects a crash into the next recorded write:
  1 drops the P/Q writes, 2 drops the data writes, then the kernel panics once
  the remaining writes completed; 4 panics the next parity scrub (the log
  replay) before its parity write.  Mounting afterwards and reading the
  previously committed data with any one device missing demonstrates the
  problem on a kernel without the log and its absence with it.
* ``tools/testing/btrfs/raid56_wib_dump.py`` prints the log blocks of a
  device or image.
