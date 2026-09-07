# RAID5/6 Rebuild Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every RAID5/6 reconstruction checked before it is handed to a reader or written back to disk.

**Architecture:** The read-rebuild path never loads checksums, so its verification hooks are dead code — `recover_rbio()` does not call `fill_data_csums()`, which only the read-modify-write path does. Load them there, add a metadata equivalent for chunks the checksum tree does not cover, and record on the rbio whether the rebuild was actually verified so the repair write-back gate in `bio.c` can consult knowledge instead of guessing from the chunk profile.

**Tech Stack:** C, Linux kernel 7.3-rc2, `fs/btrfs`. Tests are User Mode Linux scenarios under `tools/testing/btrfs/uml/` plus the in-kernel self-tests under `CONFIG_BTRFS_FS_RUN_SANITY_TESTS`.

**Spec:** `docs/superpowers/plans/2026-09-07-btrfs-integrity-roadmap.md` (unit A-1), which in turn draws on the report *After the Write Hole*.

## Global Constraints

Inherited verbatim from the spec; every task's requirements include these.

- **Crash safety.** No interruption point may leave the filesystem unrecoverable. Demonstrated with the rig's crash points, not by inspection.
- **Interrupt and cancellation safety.** Every new `wait_event()` justifies being uninterruptible or uses a killable variant.
- **Timeout and hang resistance.** Every wait states what happens if the event never arrives. No new lock-order inversions; validated under `CONFIG_PROVE_LOCKING`.
- **Misbehaving devices.** Correct against devices that lose writes, lie about flushes, misdirect writes, or return stale content.
- **No unverified reconstruction is ever persisted.**
- **Every fix carries a test that fails without it.**
- Kernel style: tabs, `btrfs_` prefix on non-static functions, no line over 100 columns, `checkpatch.pl --strict` clean for new code.
- Build clean at `make W=1 fs/btrfs/` for x86_64 and `ARCH=um`.

## Environment

All test commands assume:

```bash
export BTRFS_TEST_DIR=/var/tmp/btrfs-test
```

and two UML kernels built per `tools/testing/btrfs/uml/README.md`:
`$BTRFS_TEST_DIR/uml-fast` (lockdep) and `$BTRFS_TEST_DIR/uml` (KASAN).

---

### Task 1: A scenario that proves the gap

A RAID6 stripe with one erasure *and* one silently corrupt neighbour is
recoverable in principle: two syndromes, two unknowns. Today the
reconstruction does not know the neighbour is corrupt, so it feeds bad bytes
into the rebuild and the answer is wrong. This scenario captures that, and
fails until Task 2.

**Files:**
- Modify: `tools/testing/btrfs/uml/init-final3.sh` (add a `corrupt_neighbour` mode next to the existing `stale_parity` mode)

**Interfaces:**
- Produces: a scenario selected by `MODE=corrupt_neighbour`, and a verify mode `MODE=corrupt_neighbour_verify` that reports one of `NEIGHBOUR_READ_CORRECT`, `NEIGHBOUR_READ_REFUSED` or `NEIGHBOUR_READ_WRONG`. Later tasks reuse `NEIGHBOUR_READ_CORRECT` as their pass condition.

- [ ] **Step 1: Add the scenario that corrupts a neighbour and reads through a rebuild**

Insert before the `devstats)` case in `init-final3.sh`:

```bash
corrupt_neighbour)
	# RAID6, checksummed data. Corrupt one data stripe's bytes on disk
	# behind btrfs's back, then read a *different* data stripe with its
	# device missing. The rebuild needs the corrupt stripe as an input.
	# With two syndromes this is solvable, but only if the corruption is
	# noticed; otherwise the answer is wrong.
	dm_setup
	mkfs.btrfs -q -f -d $DPROF -m $MPROF $DMDEVS || { log "MKFS_FAIL"; finish; }
	dm_scan
	do_mount $OPTS /dev/mapper/d0
	dd if=/dev/urandom of=$MNT/f bs=64K count=16 conv=fsync status=none
	sync
	md5sum $MNT/f | awk '{print $1}' > $T/umltest/old.md5.$TAG
	log "file md5 $(cat $T/umltest/old.md5.$TAG)"
	L=$(filefrag -v $MNT/f | sed -n 4p | awk -F: '{print $3}' | awk '{print $1}' | tr -d '.')
	log "first logical block $L"
	umount $MNT
	# Corrupt 4K of the second data stripe of the first full stripe.
	btrfs-map-logical -l $(( (L * 4096) + 65536 )) -b 4096 /dev/mapper/d0 \
		> $T/umltest/map.$TAG 2>&1
	cat $T/umltest/map.$TAG | while read -r l; do log "map: $l"; done
	DEV=$(awk '/mirror 1/ {print $NF}' $T/umltest/map.$TAG | head -1)
	OFF=$(awk '/mirror 1/ {for(i=1;i<=NF;i++) if($i=="physical") print $(i+1)}' \
		$T/umltest/map.$TAG | head -1)
	if [ -n "$DEV" ] && [ -n "$OFF" ]; then
		dd if=/dev/urandom of=$DEV bs=4096 count=1 seek=$((OFF / 4096)) \
			conv=notrunc status=none
		log "CORRUPTED $DEV at $OFF"
	else
		log "CORRUPT_FAILED (no mapping)"
	fi
	dmsetup remove_all
	finish
	;;
corrupt_neighbour_verify)
	dm_setup
	dm_scan
	do_mount "$OPTS,degraded" /dev/mapper/d0
	echo 3 > /proc/sys/vm/drop_caches
	M=$(md5sum $MNT/f 2>/dev/null | awk '{print $1}')
	WANT=$(cat $T/umltest/old.md5.$TAG)
	if [ -z "$M" ]; then
		log "NEIGHBOUR_READ_REFUSED (detected, not repaired)"
	elif [ "$M" = "$WANT" ]; then
		log "NEIGHBOUR_READ_CORRECT"
	else
		log "NEIGHBOUR_READ_WRONG md5=$M want=$WANT"
	fi
	kmsg "csum|raid56|corrupt" 8
	umount $MNT || log "UMOUNT_FAIL"
	dmsetup remove_all
	finish
	;;
```

- [ ] **Step 2: Run it and confirm the rebuild is wrong today**

```bash
cd tools/testing/btrfs/uml
./dmfail34.sh $BTRFS_TEST_DIR/uml-fast/linux t1-neighbour corrupt_neighbour raid6:raid6 rw 5 0
```

Expected: `NEIGHBOUR_READ_WRONG` or `NEIGHBOUR_READ_REFUSED` — the data is
not returned correctly even though two syndromes make it recoverable.
Record which, so Task 2 can show the change.

- [ ] **Step 3: Commit the scenario**

```bash
git add tools/testing/btrfs/uml/init-final3.sh
git commit -m "btrfs: test: read a RAID6 stripe with an erasure and a corrupt neighbour"
```

---

### Task 2: Load checksums on the recovery path

**Files:**
- Modify: `fs/btrfs/raid56.c` — `recover_rbio()` (at the `alloc_rbio_pages()` call)

**Interfaces:**
- Consumes: `fill_data_csums(struct btrfs_raid_bio *rbio)`, already defined in this file and currently called only from `rmw_read_wait_recover()`.
- Produces: on return from `recover_rbio()`'s read phase, `rbio->csum_bitmap` and `rbio->csum_buf` are populated for data block groups, so `verify_bio_data_sectors()` marks corrupt *inputs* in `error_bitmap` before reconstruction, and `verify_one_sector()` checks each rebuilt sector.

- [ ] **Step 1: Confirm the failing test from Task 1 still fails**

```bash
cd tools/testing/btrfs/uml
./dmfail34.sh $BTRFS_TEST_DIR/uml-fast/linux t2-before corrupt_neighbour raid6:raid6 rw 5 0
```

Expected: the same non-`CORRECT` result recorded in Task 1 Step 2.

- [ ] **Step 2: Call fill_data_csums() from the recovery path**

In `recover_rbio()`, immediately after the `alloc_rbio_pages()` error check
and before `index_rbio_pages(rbio)`:

```c
	/*
	 * Load the checksums for this full stripe.  Without them
	 * verify_bio_data_sectors() cannot notice that one of the sectors we
	 * are about to reconstruct *from* is corrupt, and verify_one_sector()
	 * cannot check the result: the rebuild would be handed to the reader
	 * on the strength of the parity alone.
	 *
	 * fill_data_csums() skips metadata and mixed block groups, which is
	 * what keeps the csum tree lookup from recursing into a recovery of
	 * the stripe we already hold locked.
	 */
	fill_data_csums(rbio);
```

- [ ] **Step 3: Build and run the test**

```bash
make -j$(nproc) O=$BTRFS_TEST_DIR/x86 W=1 fs/btrfs/
make -j$(nproc) ARCH=um O=$BTRFS_TEST_DIR/uml-fast linux
cd tools/testing/btrfs/uml
./dmfail34.sh $BTRFS_TEST_DIR/uml-fast/linux t2-after corrupt_neighbour raid6:raid6 rw 5 0
```

Expected: `NEIGHBOUR_READ_CORRECT`. RAID6 now locates the corrupt neighbour
as a second erasure and solves for both.

- [ ] **Step 4: Confirm no regression and no lock-order inversion**

```bash
cd tools/testing/btrfs/uml
./run3.sh $BTRFS_TEST_DIR/uml-fast/linux t2-r5 raid5:raid1 rw 1 4
./run3.sh $BTRFS_TEST_DIR/uml-fast/linux t2-r6 raid6:raid6 rw 1 4
./dmfail34.sh $BTRFS_TEST_DIR/uml-fast/linux t2-detach detach raid5:raid5 rw 4 2
grep -l "possible circular\|lockdep\|BUG:" $BTRFS_TEST_DIR/umltest/t2-*/log.* || echo "no splats"
```

Expected: every scenario reports `bad=0`, and no lockdep splat. The
deadlock guard being relied on is the one already documented in
`fill_data_csums()`; this step is what demonstrates it holds on the read
path too.

- [ ] **Step 5: Commit**

```bash
git add fs/btrfs/raid56.c
git commit -m "btrfs: raid56: verify reconstructions on the read path"
```

---

### Task 3: Record whether the rebuild was actually verified

`verify_one_sector()` already distinguishes verified, unverifiable and bad.
Nothing keeps that verdict, so callers cannot tell a checked reconstruction
from an unchecked one.

**Files:**
- Modify: `fs/btrfs/raid56.h` (flag), `fs/btrfs/raid56.c` (`recover_vertical()`, `recover_rbio()`)

**Interfaces:**
- Consumes: `verify_one_sector()` returning `1` verified, `0` unverifiable, `-EIO` bad.
- Produces: `RBIO_UNVERIFIED_REBUILD_BIT`, set on `rbio->flags` when any sector was reconstructed without anything vouching for it. Task 4 reads it.

- [ ] **Step 1: Add the flag**

In `fs/btrfs/raid56.c`, next to the other `RBIO_*_BIT` definitions:

```c
/*
 * Set when a sector was reconstructed and nothing could vouch for the
 * result: no data checksum, and no second syndrome to cross-check against.
 * The content may be handed to the reader, but must not be written back.
 */
#define RBIO_UNVERIFIED_REBUILD_BIT	5
```

- [ ] **Step 2: Set it where the verdict is known**

In `recover_vertical()`, in the `faila >= 0` branch, replace the existing
cross-check block with one that also records the verdict:

```c
		if (ret == 0 && scratch_p && failb < 0 && faila < rbio->nr_data) {
			ret = recover_verify_q(rbio, sector_nr, pointers,
					       unmap_array, scratch_p, scratch_q);
			if (ret < 0)
				return ret;
			/* The syndrome vouched for it. */
			ret = 1;
		}
		if (ret == 0)
			set_bit(RBIO_UNVERIFIED_REBUILD_BIT, &rbio->flags);
```

and in the `failb >= 0` branch, after its `verify_one_sector()` call:

```c
		if (ret == 0)
			set_bit(RBIO_UNVERIFIED_REBUILD_BIT, &rbio->flags);
```

- [ ] **Step 3: Add a self test for the flag's encoding**

In `fs/btrfs/tests/raid56-wib-tests.c`, add to `btrfs_test_raid56_wib()`
before `btrfs_free_dummy_fs_info()`:

```c
	/* The rebuild-verdict flag must not collide with the cache bits. */
	if (RBIO_UNVERIFIED_REBUILD_BIT == RBIO_CACHE_READY_BIT ||
	    RBIO_UNVERIFIED_REBUILD_BIT == RBIO_INPLACE_BIT) {
		test_err("rebuild verdict flag collides with an existing bit");
		ret = -EINVAL;
		goto out;
	}
```

- [ ] **Step 4: Build and run the self tests**

```bash
make -j$(nproc) ARCH=um O=$BTRFS_TEST_DIR/uml-fast linux
cd tools/testing/btrfs/uml && ./selftest.sh
```

Expected: `running raid56 write-intent log tests` with no `test_err` line.

- [ ] **Step 5: Commit**

```bash
git add fs/btrfs/raid56.c fs/btrfs/tests/raid56-wib-tests.c
git commit -m "btrfs: raid56: record whether a reconstruction was verified"
```

---

### Task 4: Gate the repair write-back on the verdict, not the profile

`repair_read_is_reconstruction()` asks the chunk map whether this is a
RAID5/6 profile and assumes any mirror above 1 is therefore unverifiable.
That is now answerable exactly.

**Files:**
- Modify: `fs/btrfs/raid56.c` (export the verdict), `fs/btrfs/raid56.h`, `fs/btrfs/bio.c` (`btrfs_end_repair_bio()`)

**Interfaces:**
- Consumes: `RBIO_UNVERIFIED_REBUILD_BIT` from Task 3.
- Produces: `bool btrfs_raid56_last_repair_was_verified(struct btrfs_bio *bbio)` — declared in `raid56.h`, used only by `bio.c`.

- [ ] **Step 1: Write the failing test**

Extend the Task 1 verify mode so it also asserts the corrupt sector was
repaired on disk. Add to `corrupt_neighbour_verify)` before the `umount`:

```bash
	# With every device present the corrupt sector must now be repaired,
	# because the rebuild that fixed it was checked against a checksum.
	umount $MNT; dmsetup remove_all; dm_setup; dm_scan
	do_mount $OPTS /dev/mapper/d0
	echo 3 > /proc/sys/vm/drop_caches
	M2=$(md5sum $MNT/f 2>/dev/null | awk '{print $1}')
	[ "$M2" = "$WANT" ] && log "NEIGHBOUR_REPAIRED" || log "NEIGHBOUR_NOT_REPAIRED"
```

- [ ] **Step 2: Run it and record the result before the change**

```bash
cd tools/testing/btrfs/uml
./dmfail34.sh $BTRFS_TEST_DIR/uml-fast/linux t4-before corrupt_neighbour raid6:raid6 rw 5 0
```

Expected: `NEIGHBOUR_REPAIRED` is absent or reports not-repaired, because
the profile-based gate refuses every RAID5/6 write-back.

- [ ] **Step 3: Export the verdict**

In `fs/btrfs/raid56.c`:

```c
bool btrfs_raid56_last_repair_was_verified(struct btrfs_bio *bbio)
{
	return !test_bit(RBIO_UNVERIFIED_REBUILD_BIT, &bbio->rbio_flags);
}
```

Declare it in `fs/btrfs/raid56.h`:

```c
bool btrfs_raid56_last_repair_was_verified(struct btrfs_bio *bbio);
```

Carry the flag out of the rbio by copying it into the bbio in
`rbio_orig_end_io()`, before `rbio_endio_bio_list()`:

```c
	if (test_bit(RBIO_UNVERIFIED_REBUILD_BIT, &rbio->flags)) {
		struct bio *b;

		for (b = cur; b; b = b->bi_next)
			set_bit(RBIO_UNVERIFIED_REBUILD_BIT,
				&btrfs_bio(b)->rbio_flags);
	}
```

Add `unsigned long rbio_flags;` to `struct btrfs_bio` in `fs/btrfs/bio.h`,
outside the union, with the comment:

```c
	/* Verdict from a RAID56 reconstruction, see raid56.h. */
	unsigned long rbio_flags;
```

- [ ] **Step 4: Use it in the gate**

In `fs/btrfs/bio.c`, replace the body of `repair_read_is_reconstruction()`:

```c
	if (mirror_num <= 1)
		return false;
	if (!btrfs_logical_is_raid56(fs_info, logical))
		return false;
	/* A RAID56 rebuild that something vouched for is safe to persist. */
	return !btrfs_raid56_last_repair_was_verified(repair_bbio);
```

and pass `repair_bbio` in at its call site.

- [ ] **Step 5: Build and run**

```bash
make -j$(nproc) O=$BTRFS_TEST_DIR/x86 W=1 fs/btrfs/
make -j$(nproc) ARCH=um O=$BTRFS_TEST_DIR/uml-fast linux
cd tools/testing/btrfs/uml
./dmfail34.sh $BTRFS_TEST_DIR/uml-fast/linux t4-after corrupt_neighbour raid6:raid6 rw 5 0
./staleq.sh $BTRFS_TEST_DIR/uml-fast/linux t4-stale 2
```

Expected: `NEIGHBOUR_REPAIRED`, and `staleq.sh` still shows the
unverifiable case being refused rather than persisted.

- [ ] **Step 6: Commit**

```bash
git add fs/btrfs/raid56.c fs/btrfs/raid56.h fs/btrfs/bio.c fs/btrfs/bio.h \
	tools/testing/btrfs/uml/init-final3.sh
git commit -m "btrfs: persist a RAID56 rebuild when it was verified"
```

---

### Task 5: Verify metadata on the RAID5/6 path

`fill_data_csums()` returns early for any non-data block group, so a
metadata chunk on RAID5/6 is reconstructed with no verification at all — and
on RAID5 there is no second syndrome either. Every tree block carries its
own checksum; use it.

**Files:**
- Modify: `fs/btrfs/raid56.c` (new `verify_one_metadata_sector()`, called from `verify_one_sector()`)

**Interfaces:**
- Consumes: `btrfs_calculate_block_csum_pages()`, `rbio->bioc->full_stripe_logical`, `fs_info->nodesize`.
- Produces: `verify_one_sector()` returning `1`/`0`/`-EIO` for metadata chunks as it already does for data.

- [ ] **Step 1: Write the failing test**

Add a `corrupt_meta` mode to `init-final3.sh`, identical to
`corrupt_neighbour` except the profile is `raid5:raid6`, the file is
replaced by `for i in $(seq 1 400); do mkdir -p $MNT/d/$i; done; sync` to
force metadata into the RAID6 chunk, and the verification reads the tree
back with `btrfs check --readonly`, reporting `META_OK` or `META_BAD`.

- [ ] **Step 2: Run it and confirm metadata corruption is not caught**

```bash
cd tools/testing/btrfs/uml
./dmfail34.sh $BTRFS_TEST_DIR/uml-fast/linux t5-before corrupt_meta raid5:raid6 rw 5 0
```

Expected: `META_BAD` — the corrupt tree block is folded into the rebuild.

- [ ] **Step 3: Add the metadata verifier**

In `fs/btrfs/raid56.c`, above `verify_one_sector()`:

```c
/*
 * Check a sector of a metadata chunk against the tree block it holds.
 *
 * fill_data_csums() covers data block groups only, so this is the only
 * evidence available for metadata on RAID5/6 — and on RAID5 there is no
 * second syndrome either, so without it a reconstruction is trusted with
 * nothing at all.
 *
 * Returns 1 when the tree block verified, 0 when this sector does not begin
 * one (free space, or the middle of a block), and -EIO on a mismatch.
 */
static int verify_one_metadata_sector(struct btrfs_raid_bio *rbio,
				      int stripe_nr, int sector_nr)
{
	struct btrfs_fs_info *fs_info = rbio->bioc->fs_info;
	const u32 sectorsize = fs_info->sectorsize;
	const u64 logical = rbio->bioc->full_stripe_logical +
			    (u64)stripe_nr * BTRFS_STRIPE_LEN +
			    (u64)sector_nr * sectorsize;
	struct btrfs_header *header;
	u8 csum[BTRFS_CSUM_SIZE];
	phys_addr_t *paddrs;
	void *kaddr;
	int ret = 0;

	if (!IS_ALIGNED(logical, fs_info->nodesize))
		return 0;
	if (sector_nr * sectorsize + fs_info->nodesize > BTRFS_STRIPE_LEN)
		return 0;

	paddrs = rbio_stripe_paddrs(rbio, stripe_nr, sector_nr);
	kaddr = kmap_local_paddr(paddrs[0]);
	header = kaddr;
	/*
	 * A tree block that does not claim this address is free space or a
	 * stale leftover, not a corruption of the block we care about.
	 */
	if (btrfs_stack_header_bytenr(header) != logical ||
	    memcmp(header->fsid, fs_info->fs_devices->metadata_uuid,
		   BTRFS_FSID_SIZE) != 0) {
		kunmap_local(kaddr);
		return 0;
	}
	kunmap_local(kaddr);

	btrfs_calculate_block_csum_pages(fs_info, paddrs, csum);
	kaddr = kmap_local_paddr(paddrs[0]);
	if (memcmp(csum, kaddr, fs_info->csum_size) != 0)
		ret = -EIO;
	else
		ret = 1;
	kunmap_local(kaddr);
	return ret;
}
```

- [ ] **Step 4: Call it**

In `verify_one_sector()`, replace the early return for a missing csum
bitmap:

```c
	if (!rbio->csum_bitmap || !rbio->csum_buf) {
		if (rbio->bioc->map_type & BTRFS_BLOCK_GROUP_METADATA)
			return verify_one_metadata_sector(rbio, stripe_nr,
							  sector_nr);
		return 0;
	}
```

- [ ] **Step 5: Build and run**

```bash
make -j$(nproc) O=$BTRFS_TEST_DIR/x86 W=1 fs/btrfs/
make -j$(nproc) ARCH=um O=$BTRFS_TEST_DIR/uml-fast linux
cd tools/testing/btrfs/uml
./dmfail34.sh $BTRFS_TEST_DIR/uml-fast/linux t5-after corrupt_meta raid5:raid6 rw 5 0
./run3.sh $BTRFS_TEST_DIR/uml-fast/linux t5-r5m raid5:raid5 rw 2 4
```

Expected: `META_OK`, and the metadata-on-RAID5 crash scenario still
reports `bad=0`.

- [ ] **Step 6: Commit**

```bash
git add fs/btrfs/raid56.c tools/testing/btrfs/uml/init-final3.sh
git commit -m "btrfs: raid56: verify metadata reconstructions against the tree block"
```

---

### Task 6: Attribute corruption found on the RAID5/6 path to its device

When `verify_bio_data_sectors()` catches a mismatch it knows which stripe,
and therefore which device, returned the bad bytes. The counter that exists
for exactly this is never incremented.

**Files:**
- Modify: `fs/btrfs/raid56.c` (`verify_bio_data_sectors()`)

**Interfaces:**
- Consumes: `rbio_bio_device()`, already in this file.
- Produces: nothing for later tasks; user-visible through `btrfs device stats`.

- [ ] **Step 1: Write the failing test**

Add to `corrupt_neighbour_verify)`, after the read:

```bash
	btrfs device stats $MNT | grep -q "corruption_errs *[1-9]" \
		&& log "CORRUPTION_ATTRIBUTED" || log "CORRUPTION_NOT_ATTRIBUTED"
```

- [ ] **Step 2: Run it**

```bash
cd tools/testing/btrfs/uml
./dmfail34.sh $BTRFS_TEST_DIR/uml-fast/linux t6-before corrupt_neighbour raid6:raid6 rw 5 0
```

Expected: `CORRUPTION_NOT_ATTRIBUTED`.

- [ ] **Step 3: Count it**

In `verify_bio_data_sectors()`, where the mismatch is detected, after the
existing error-bit handling:

```c
		{
			struct btrfs_device *dev = rbio_bio_device(rbio, bio);

			if (dev)
				btrfs_dev_stat_inc_and_print(dev,
					BTRFS_DEV_STAT_CORRUPTION_ERRS);
		}
```

- [ ] **Step 4: Build and run**

```bash
make -j$(nproc) O=$BTRFS_TEST_DIR/x86 W=1 fs/btrfs/
make -j$(nproc) ARCH=um O=$BTRFS_TEST_DIR/uml-fast linux
cd tools/testing/btrfs/uml
./dmfail34.sh $BTRFS_TEST_DIR/uml-fast/linux t6-after corrupt_neighbour raid6:raid6 rw 5 0
```

Expected: `CORRUPTION_ATTRIBUTED`.

- [ ] **Step 5: Commit**

```bash
git add fs/btrfs/raid56.c tools/testing/btrfs/uml/init-final3.sh
git commit -m "btrfs: raid56: count corruption against the device that returned it"
```

---

### Task 7: Full regression and the constraint matrix

**Files:** none modified; this task is the gate.

- [ ] **Step 1: Run the whole scenario matrix on both kernels**

```bash
cd tools/testing/btrfs/uml
for k in uml-fast uml; do
  ./run3.sh $BTRFS_TEST_DIR/$k/linux g1-$k-r5 raid5:raid1 rw 1 4
  ./run3.sh $BTRFS_TEST_DIR/$k/linux g1-$k-r6 raid6:raid6 rw 1 4
  PREPARE_MODE=inplace ./run3.sh $BTRFS_TEST_DIR/$k/linux g1-$k-ip raid5:raid5 rw 1 4
  PREPARE_MODE=prepare_fsync ./run3.sh $BTRFS_TEST_DIR/$k/linux g1-$k-fs raid5:raid5 rw 1 4
  ./dmfail34.sh $BTRFS_TEST_DIR/$k/linux g1-$k-fl flakey raid5:raid5 rw 4 1
  ./dmfail34.sh $BTRFS_TEST_DIR/$k/linux g1-$k-dt detach raid5:raid5 rw 4 2
  ./degraded23.sh $BTRFS_TEST_DIR/$k/linux g1-$k-dg raid5:raid5 rw 1 4 0
  ./misc3.sh $BTRFS_TEST_DIR/$k/linux g1-$k-rp replace raid5:raid1 rw 5
  ./stress23.sh $BTRFS_TEST_DIR/$k/linux g1-$k-st raid5:raid5 rw 4 3
done
grep -c "_FAIL\|_BAD\|SPLAT\|bad=[1-9]" $BTRFS_TEST_DIR/umltest/results.g1-*
```

Expected: zero matches on every result file.

- [ ] **Step 2: Check the constraints the plan inherited**

Crash safety is covered by the crash points in the scenarios above.
For the rest:

```bash
# Interrupt safety: kill a mount mid-recovery, then mount properly.
cd tools/testing/btrfs/uml
./run3.sh $BTRFS_TEST_DIR/uml-fast/linux g2-kill raid5:raid5 rw 1 4 &
sleep 25; pkill -9 -f "linux mem=1G"; wait
./run3.sh $BTRFS_TEST_DIR/uml-fast/linux g2-after raid5:raid5 rw 1 4

# Timeouts and lock order: the KASAN+lockdep kernel under load.
./misc3.sh $BTRFS_TEST_DIR/uml/linux g2-load writers raid5:raid5 rw 4
grep -l "possible circular\|hung task\|INFO: task" $BTRFS_TEST_DIR/umltest/g2-*/log.* \
	|| echo "no hangs or inversions"
```

Expected: the second mount recovers cleanly, and no lockdep or hung-task
report.

- [ ] **Step 3: Style and build**

```bash
git diff --stat HEAD~6..HEAD
git diff HEAD~6..HEAD | ./scripts/checkpatch.pl --no-tree --strict - \
	| grep -E "^(ERROR|WARNING)" | sort | uniq -c
make -j$(nproc) O=$BTRFS_TEST_DIR/x86 W=1 fs/btrfs/
```

Expected: no checkpatch ERROR, no new WARNING beyond the MAINTAINERS note
for added files, and a clean `W=1` build.

- [ ] **Step 4: Update the report and push**

Mark items 1, 2 and 5 of *After the Write Hole* as done, note that the
"refuse unverifiable rebuilds" policy is now decidable per-rebuild rather
than per-profile, and push the branch.

```bash
git push -u origin <branch>
```

## Self-review

**Spec coverage.** Unit A-1 of the roadmap names four things: load
checksums on the recovery path (Task 2), verify metadata (Task 5), propagate
the verdict to the repair write-back gate (Tasks 3 and 4), and attribute
corruption to devices (Task 6). All four have tasks. The roadmap's global
constraints are checked in Task 7.

**Placeholders.** Every code step carries the actual code. Task 5 Step 1
describes the test scenario by its difference from the Task 1 scenario
rather than repeating 40 lines of shell; that is a deliberate exception and
the difference is stated precisely enough to write it.

**Type consistency.** `RBIO_UNVERIFIED_REBUILD_BIT` is defined in Task 3 and
consumed in Task 4 under the same name.
`btrfs_raid56_last_repair_was_verified()` is defined and declared in Task 4
Step 3 and called in Step 4 with the same signature. `rbio_flags` is added
to `struct btrfs_bio` in Task 4 Step 3 and read in the same task.
`rbio_bio_device()` used in Task 6 already exists.

**Known risk, carried deliberately.** Task 2 is one line whose whole
difficulty is the deadlock question: the csum tree lookup can read metadata,
and if that metadata needs a RAID5/6 recovery it must not be the stripe we
already hold locked. The existing guard skips metadata and mixed block
groups, which is why the read path is no worse than the RMW path that
already does this. Task 2 Step 4 is what demonstrates it rather than
asserting it; if a lockdep splat appears there, the task becomes "defer the
csum lookup to a context that does not hold the stripe lock" and grows
substantially.
