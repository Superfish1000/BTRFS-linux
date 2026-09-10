// SPDX-License-Identifier: GPL-2.0
/*
 * RAID56 write-intent log.
 *
 * [THE PROBLEM]
 *
 * A sub-stripe write on a RAID5/6 block group is a read-modify-write of the
 * full stripe: the data sectors of the higher layer bios and the recomputed
 * P/Q sectors are written as independent bios to independent devices.  If
 * the machine crashes after some of those writes reached their device and
 * others did not, the vertical stripes touched by the RMW are inconsistent:
 * P/Q no longer match the data.
 *
 * The newly written data sectors are unreferenced (btrfs is copy-on-write,
 * the transaction referencing them never committed), but the other sectors
 * of the same vertical stripes belong to committed extents.  They are still
 * readable, but they lost their redundancy: if the device holding them
 * fails, rebuilding them from the stale parity yields garbage.  This is the
 * classic RAID5/6 write hole.  In-place writes (nodatacow, preallocated
 * extents) are affected even when they cover the full stripe, because the
 * sectors being overwritten are themselves referenced.
 *
 * [THE FIX]
 *
 * Before the writes of such a RMW are submitted, the full stripe is recorded
 * in a small log that lives at a fixed location on every writable device,
 * and the log write is made durable (FUA).  After all writes of the RMW have
 * completed the stripe is removed from the in-memory set; the on-disk log is
 * rewritten lazily: the log writes issued for new RMWs only ever add to the
 * on-disk block, and a stripe is dropped from it only by the transaction
 * (or log) commit, after the commit's device barriers confirmed that every
 * device flushed its cache, so that the stripe's data and parity writes are
 * on stable media before the log stops mentioning the stripe.
 *
 * On mount, the newest valid log block of every present device is read,
 * the union taken, and every listed full stripe is scrubbed
 * (btrfs_scrub_raid56_full_stripe()): every sector holding an extent is
 * verified by checksum, bad ones are rebuilt from the existing parity, and
 * P/Q are regenerated.  Only afterwards is the filesystem written to.
 *
 * [RECORD KINDS]
 *
 * A record is either clean (the stripe had a write in flight on a fully
 * working array) or an error record (a write to the stripe failed on some
 * device, the record of a dropped stripe may not have reached a device with
 * its data flushed, or a previous recovery could not finish).
 *
 * For a clean record every present device holds what was last written to
 * it, so after the extents visible in the commit roots have been verified,
 * the parity of every vertical stripe is recomputed from the data as it is
 * on disk.  This also covers extents that are only referenced from the tree
 * log (fsync'ed data and the log tree blocks themselves), which the extent
 * tree does not know yet at that point.
 *
 * For an error record a device may hold stale sectors, so only sectors that
 * can be verified are trusted: the parity is recomputed from verified data
 * only, and if a sector cannot be repaired the parity is left alone.  The
 * record stays until a later pass can verify everything: after the tree log
 * has been replayed (so that its extents are visible), or at a later mount
 * once a missing device is back or replaced.
 *
 * [INVARIANT]
 *
 * At any instant, every full stripe that has a write whose data or parity
 * may not yet be on stable media is listed in the newest valid on-disk log
 * block of enough devices to survive the RAID's tolerated number of device
 * failures.  Proof sketch:
 *
 *  - A RMW proceeds to its writes only after a commit whose snapshot
 *    contained its stripe completed on enough devices (btrfs_wib_mark()).
 *  - A stripe is dropped from a snapshot only after btrfs_wib_done(), i.e.
 *    after all its writes completed at the device level, and only after a
 *    flush of every device that every device confirmed, which pushes those
 *    completed writes to stable media before the new log block lands.  If
 *    a device did not confirm the flush, the stripes are kept in the block
 *    as error records instead (that device may hold stale sectors).  All
 *    other blocks are supersets of the previous one, so a device that
 *    misses a write keeps a block that lists everything it may hold
 *    unflushed.
 *  - Each device alternates between its two slots and only advances after
 *    a successful write, so the block being overwritten on a device is
 *    never its newest valid one; a torn write invalidates at most the newest
 *    block, and the previous block is a superset with respect to the
 *    stripes that could still be in flight (see the points above).
 *  - Recovery uses the union of all devices' newest valid blocks.  Stale
 *    blocks (from an old device that re-joined, or a device that missed
 *    commits) can only add stripes to scrub, which is harmless: scrubbing
 *    a consistent stripe is a no-op.
 *
 * [LIMITS]
 *
 * If the array is degraded (a device missing) when the crash happens, a
 * vertical stripe whose missing sector was committed data and whose parity
 * was in the middle of an update cannot be reconstructed with certainty.
 * Recovery then relies on data checksums: the rebuild is verified and
 * refused when it does not match, so the loss is detected, not silent
 * (except for nodatasum data, which has no checksum to verify against).
 * Closing that case requires journaling the data itself, which this log
 * does not do.
 */

#include <linux/bio.h>
#include <linux/blkdev.h>
#include <linux/file.h>
#include <linux/slab.h>
#include <linux/sort.h>
#include <linux/mm.h>
#include <linux/rcupdate.h>
#include <linux/sched/mm.h>
#include "messages.h"
#include "ctree.h"
#include "fs.h"
#include "volumes.h"
#include "raid56.h"
#include "raid56-wib.h"
#include "scrub.h"
#include "disk-io.h"
#include "accessors.h"
#include "zoned.h"

static_assert(sizeof(struct btrfs_wib_disk_header) == 128);
static_assert(sizeof(struct btrfs_wib_disk_entry) == 24);
static_assert(BTRFS_WIB_MAX_ENTRIES == 165);
static_assert(BTRFS_WIB_OFFSET + BTRFS_WIB_NR_SLOTS * BTRFS_WIB_SLOT_SIZE <=
	      BTRFS_DEVICE_RANGE_RESERVED);
static_assert(BTRFS_SUPER_INFO_OFFSET + BTRFS_SUPER_INFO_SIZE <= BTRFS_WIB_OFFSET);
static_assert(BTRFS_WIB_BLOCK_SHIFT == BTRFS_STRIPE_LEN_SHIFT);

static inline u64 wib_entry_bytenr(u64 logical)
{
	return logical & ~(BTRFS_WIB_ENTRY_SIZE - 1);
}

/*
 * Return the bitmap of blocks of the entry at @bytenr that intersect
 * [@logical, @logical + @len).
 */
u64 btrfs_wib_range_mask(u64 bytenr, u64 logical, u64 len)
{
	const u64 start = max(logical, bytenr);
	const u64 end = min(logical + len, bytenr + BTRFS_WIB_ENTRY_SIZE);
	unsigned int first;
	unsigned int last;

	if (start >= end)
		return 0;
	first = (start - bytenr) >> BTRFS_WIB_BLOCK_SHIFT;
	last = (end - 1 - bytenr) >> BTRFS_WIB_BLOCK_SHIFT;
	return GENMASK_ULL(last, first);
}

static bool wib_entry_used(const struct btrfs_wib_entry *e)
{
	return (e->bitmap | e->sticky) != 0;
}

static struct btrfs_wib_entry *wib_find_entry(struct btrfs_wib *wib, u64 bytenr)
{
	lockdep_assert_held(&wib->lock);

	for (int i = 0; i < BTRFS_WIB_MAX_ENTRIES; i++) {
		struct btrfs_wib_entry *e = &wib->entries[i];

		if (wib_entry_used(e) && e->bytenr == bytenr)
			return e;
	}
	return NULL;
}

/*
 * Make room by dropping an entry that only records stripes without a write
 * in flight (sticky).  Those stripes then rely on scrub instead of the
 * mount-time recovery.
 */
static struct btrfs_wib_entry *wib_evict_sticky(struct btrfs_wib *wib)
{
	lockdep_assert_held(&wib->lock);

	for (int i = 0; i < BTRFS_WIB_MAX_ENTRIES; i++) {
		struct btrfs_wib_entry *e = &wib->entries[i];

		if (e->bitmap || !e->sticky)
			continue;
		if (!btrfs_is_testing(wib->fs_info))
			btrfs_warn_rl(wib->fs_info,
	"raid56 write-intent log full, dropping record of %u stripes with failed writes at %llu, run scrub",
				      (unsigned int)hweight64(e->sticky), e->bytenr);
		atomic64_inc(&wib->stat_sticky_evicted);
		e->sticky = 0;
		return e;
	}
	return NULL;
}

/*
 * Find the entry for @bytenr, or claim a free one, evicting a sticky-only
 * entry if @evict and nothing is free.  NULL if the log is full.
 */
static struct btrfs_wib_entry *wib_find_or_alloc_entry(struct btrfs_wib *wib,
						       u64 bytenr, bool evict)
{
	struct btrfs_wib_entry *free = NULL;

	lockdep_assert_held(&wib->lock);

	for (int i = 0; i < BTRFS_WIB_MAX_ENTRIES; i++) {
		struct btrfs_wib_entry *e = &wib->entries[i];

		if (!wib_entry_used(e)) {
			if (!free)
				free = e;
			continue;
		}
		if (e->bytenr == bytenr)
			return e;
	}
	if (!free && evict)
		free = wib_evict_sticky(wib);
	if (free) {
		free->bytenr = bytenr;
		free->sticky = 0;
	}
	return free;
}

/*
 * Number of entries [@logical, @logical + @len) needs that don't exist yet,
 * and the number of entries that could hold them (free ones, plus
 * sticky-only ones outside the range that can be evicted).
 */
static void wib_count_entries_locked(struct btrfs_wib *wib, u64 logical, u64 len,
				     unsigned int *needed, unsigned int *avail)
{
	const u64 first = wib_entry_bytenr(logical);
	const u64 last = wib_entry_bytenr(logical + len - 1);

	lockdep_assert_held(&wib->lock);

	*needed = 0;
	*avail = 0;
	for (u64 cur = first; cur <= last; cur += BTRFS_WIB_ENTRY_SIZE) {
		if (!wib_find_entry(wib, cur))
			(*needed)++;
	}
	for (int i = 0; i < BTRFS_WIB_MAX_ENTRIES; i++) {
		const struct btrfs_wib_entry *e = &wib->entries[i];

		if (!wib_entry_used(e))
			(*avail)++;
		else if (!e->bitmap && (e->bytenr < first || e->bytenr > last))
			(*avail)++;
	}
}

/* True if btrfs_wib_try_mark() for the same range would succeed. */
bool btrfs_wib_can_mark(struct btrfs_wib *wib, u64 logical, u64 len)
{
	unsigned int needed;
	unsigned int avail;

	spin_lock(&wib->lock);
	wib_count_entries_locked(wib, logical, len, &needed, &avail);
	spin_unlock(&wib->lock);
	return needed <= avail;
}

/*
 * Set the in-flight bits for [@logical, @logical + @len) without blocking.
 *
 * Return 0 on success, -ENOSPC if the log has no room for the entries the
 * range needs (nothing is modified in that case).
 */
int btrfs_wib_try_mark(struct btrfs_wib *wib, u64 logical, u64 len)
{
	const u64 end = logical + len;
	unsigned int needed;
	unsigned int avail;
	u64 cur;

	lockdep_assert_held(&wib->lock);

	wib_count_entries_locked(wib, logical, len, &needed, &avail);
	if (needed > avail)
		return -ENOSPC;

	/*
	 * Mark the existing entries first: an existing sticky-only entry of
	 * the range gets in-flight bits and can then not be evicted by the
	 * allocations below.
	 */
	for (cur = wib_entry_bytenr(logical); cur < end; cur += BTRFS_WIB_ENTRY_SIZE) {
		struct btrfs_wib_entry *e = wib_find_entry(wib, cur);

		if (e)
			e->bitmap |= btrfs_wib_range_mask(cur, logical, len);
	}
	for (cur = wib_entry_bytenr(logical); cur < end; cur += BTRFS_WIB_ENTRY_SIZE) {
		struct btrfs_wib_entry *e;

		if (wib_find_entry(wib, cur))
			continue;
		e = wib_find_or_alloc_entry(wib, cur, true);
		/* The counting above guarantees the room. */
		ASSERT(e);
		e->bitmap |= btrfs_wib_range_mask(cur, logical, len);
	}
	return 0;
}

/*
 * Snapshot the in-flight set into @block (commit_mutex held).  If @base is
 * a valid block, everything it lists is kept listed as well (the result is
 * a superset of @base, so no flush is needed before writing it); -ENOSPC if
 * that does not fit.
 */
int btrfs_wib_build_block(struct btrfs_wib *wib, void *block, u64 seq, const void *base)
{
	struct btrfs_fs_info *fs_info = wib->fs_info;
	struct btrfs_wib_disk_header *hdr = block;
	struct btrfs_wib_disk_entry *de = block + sizeof(*hdr);
	u32 nr = 0;

	/*
	 * @base is unioned in below, after this memset has cleared @block.
	 * Aliasing them would zero the base and silently drop everything it
	 * lists.
	 */
	ASSERT(block != base);
	memset(block, 0, BTRFS_WIB_SLOT_SIZE);

	spin_lock(&wib->lock);
	for (int i = 0; i < BTRFS_WIB_MAX_ENTRIES; i++) {
		const struct btrfs_wib_entry *e = &wib->entries[i];

		if (!wib_entry_used(e))
			continue;
		de[nr].bytenr = cpu_to_le64(e->bytenr);
		de[nr].bitmap = cpu_to_le64(e->bitmap);
		de[nr].error = cpu_to_le64(e->sticky);
		nr++;
	}
	spin_unlock(&wib->lock);

	if (base) {
		const struct btrfs_wib_disk_header *bh = base;
		const struct btrfs_wib_disk_entry *be = base + sizeof(*bh);
		/*
		 * @base is always a block this kernel built -- wib->last or
		 * wib->prepared -- so its count is in range.  Nothing here
		 * enforces that though, and an out-of-range count would walk
		 * be[] off the end of the slot, so clamp rather than trust
		 * the caller to stay disciplined.
		 */
		const u32 bnr = min_t(u32,
				      le64_to_cpu(bh->magic) == BTRFS_WIB_MAGIC ?
				      le32_to_cpu(bh->nr_entries) : 0,
				      BTRFS_WIB_MAX_ENTRIES);

		for (u32 i = 0; i < bnr; i++) {
			u32 j;

			for (j = 0; j < nr; j++) {
				if (de[j].bytenr == be[i].bytenr)
					break;
			}
			if (j == nr) {
				if (nr == BTRFS_WIB_MAX_ENTRIES)
					return -ENOSPC;
				de[nr++] = be[i];
				continue;
			}
			de[j].bitmap |= be[i].bitmap;
			de[j].error |= be[i].error;
		}
	}

	memcpy(hdr->fsid, fs_info->fs_devices->metadata_uuid, BTRFS_FSID_SIZE);
	hdr->magic = cpu_to_le64(BTRFS_WIB_MAGIC);
	hdr->seq = cpu_to_le64(seq);
	hdr->nr_entries = cpu_to_le32(nr);
	hdr->block_shift = cpu_to_le32(BTRFS_WIB_BLOCK_SHIFT);
	btrfs_csum(fs_info->csum_type, block + BTRFS_CSUM_SIZE,
		   BTRFS_WIB_SLOT_SIZE - BTRFS_CSUM_SIZE, hdr->csum);
	return 0;
}

bool btrfs_wib_block_valid(const struct btrfs_fs_info *fs_info, const void *block)
{
	const struct btrfs_wib_disk_header *hdr = block;
	const struct btrfs_wib_disk_entry *de;
	u8 csum[BTRFS_CSUM_SIZE];

	if (le64_to_cpu(hdr->magic) != BTRFS_WIB_MAGIC)
		return false;
	/*
	 * Written with metadata_uuid; also accept the fsid so that a
	 * btrfstune -m/-M between the crash and the mount doesn't hide the
	 * log.
	 */
	if (memcmp(hdr->fsid, fs_info->fs_devices->metadata_uuid, BTRFS_FSID_SIZE) != 0 &&
	    memcmp(hdr->fsid, fs_info->fs_devices->fsid, BTRFS_FSID_SIZE) != 0)
		return false;
	if (le32_to_cpu(hdr->block_shift) != BTRFS_WIB_BLOCK_SHIFT)
		return false;
	if (le32_to_cpu(hdr->nr_entries) > BTRFS_WIB_MAX_ENTRIES)
		return false;
	/*
	 * Nothing sets these yet, and btrfs_wib_build_block() zeroes the whole
	 * slot, so a block that has them set was written by something this
	 * kernel does not understand.  Reject it rather than guess: ignoring a
	 * log leaves the stripes it covers unrecovered, which is exactly the
	 * behaviour without the feature, whereas misreading one could scrub
	 * the wrong stripes or silently skip the right ones.  The feature is
	 * compat_ro, so an older kernel will not have written this block --
	 * only a newer one with a format change will, which is the case this
	 * guards.  block_shift above is checked for the same reason.
	 */
	if (hdr->flags != 0)
		return false;
	for (int i = 0; i < ARRAY_SIZE(hdr->reserved); i++)
		if (hdr->reserved[i] != 0)
			return false;
	btrfs_csum(fs_info->csum_type, block + BTRFS_CSUM_SIZE,
		   BTRFS_WIB_SLOT_SIZE - BTRFS_CSUM_SIZE, csum);
	if (memcmp(csum, hdr->csum, fs_info->csum_size) != 0)
		return false;
	/*
	 * Only now that the block is known to be intact, check what it says.
	 * Every user of an entry -- the union in btrfs_wib_build_block(), the
	 * lookup in wib_find_entry(), the bit arithmetic in
	 * btrfs_wib_range_mask() -- assumes the address is the base of an
	 * entry.  None of them can be made unsafe by an unaligned one
	 * (range_mask clamps to the entry and returns 0 on an empty
	 * intersection), but they would silently work on a different range
	 * than the one recorded, so recovery would scrub somewhere else and
	 * leave the real stripe alone.
	 */
	de = block + sizeof(*hdr);
	for (u32 i = 0; i < le32_to_cpu(hdr->nr_entries); i++) {
		const u64 bytenr = le64_to_cpu(de[i].bytenr);

		if (!IS_ALIGNED(bytenr, BTRFS_WIB_ENTRY_SIZE))
			return false;
		/* An entry ending past the end of the address space. */
		if (bytenr > U64_MAX - BTRFS_WIB_ENTRY_SIZE)
			return false;
	}
	return true;
}

static u64 wib_disk_entry_bits(const struct btrfs_wib_disk_entry *de)
{
	return le64_to_cpu(de->bitmap) | le64_to_cpu(de->error);
}

/* Return the bits of @oe (either kind) that @new no longer lists. */
static u64 wib_dropped_bits(const struct btrfs_wib_disk_entry *oe, const void *new)
{
	const struct btrfs_wib_disk_header *nh = new;
	const struct btrfs_wib_disk_entry *ne = new + sizeof(*nh);
	const u32 nnr = le32_to_cpu(nh->nr_entries);
	u64 bits = wib_disk_entry_bits(oe);

	for (u32 j = 0; j < nnr && bits; j++) {
		if (ne[j].bytenr == oe->bytenr)
			bits &= ~wib_disk_entry_bits(&ne[j]);
	}
	return bits;
}

/* Return true if any block listed in @old is not listed in @new. */
bool btrfs_wib_block_drops(const void *old, const void *new)
{
	const struct btrfs_wib_disk_header *oh = old;
	const struct btrfs_wib_disk_entry *oe = old + sizeof(*oh);
	const u32 onr = le32_to_cpu(oh->nr_entries);

	if (le64_to_cpu(oh->magic) != BTRFS_WIB_MAGIC)
		return false;

	for (u32 i = 0; i < onr; i++) {
		if (wib_dropped_bits(&oe[i], new))
			return true;
	}
	return false;
}

static void wib_write_end_io(struct bio *bio)
{
	struct btrfs_wib *wib = bio->bi_private;

	/* The bio is inspected and freed by the submitter after the wait. */
	if (atomic_dec_and_test(&wib->io_pending))
		wake_up(&wib->io_wait);
}

/*
 * How many device failures the RAID56 profiles in use can tolerate.  Used to
 * decide how many copies of a log block must have been written.
 */
static int wib_max_tolerated_failures(struct btrfs_fs_info *fs_info)
{
	const u64 bits = fs_info->avail_data_alloc_bits |
			 fs_info->avail_metadata_alloc_bits |
			 fs_info->avail_system_alloc_bits;

	if (bits & BTRFS_BLOCK_GROUP_RAID6)
		return 2;
	return 1;
}

/*
 * Collect a reference to the block device file of every device the log has
 * to be written to, and the slot to write on each.
 *
 * This deliberately does not take device_list_mutex: the log is written from
 * the RMW worker while the RMW's bio holds the dev-replace bio counter, and
 * btrfs_dev_replace_finishing() waits for that counter to drain while
 * holding device_list_mutex.  The device list is traversed under RCU
 * instead; a device is only closed after a grace period following its
 * removal from the list (see btrfs_rm_device() and the dev-replace teardown
 * helpers), so the file reference taken here is always on an open file.
 */
static int wib_collect_targets(struct btrfs_fs_info *fs_info,
			       struct file ***files_ret, unsigned int **slots_ret,
			       int *nr_ret)
{
	struct btrfs_fs_devices *fs_devices = fs_info->fs_devices;
	struct btrfs_device *device;
	struct file **files;
	unsigned int *slots;
	int capacity;
	int nr;

	while (true) {
		rcu_read_lock();
		capacity = 0;
		list_for_each_entry_rcu(device, &fs_devices->devices, dev_list)
			capacity++;
		rcu_read_unlock();
		capacity += 4;

		files = kcalloc(capacity, sizeof(*files), GFP_NOFS);
		slots = kcalloc(capacity, sizeof(*slots), GFP_NOFS);
		if (!files || !slots) {
			kfree(files);
			kfree(slots);
			return -ENOMEM;
		}

		nr = 0;
		rcu_read_lock();
		list_for_each_entry_rcu(device, &fs_devices->devices, dev_list) {
			struct file *bdev_file;

			if (nr == capacity)
				break;
			if (!test_bit(BTRFS_DEV_STATE_IN_FS_METADATA, &device->dev_state) ||
			    !test_bit(BTRFS_DEV_STATE_WRITEABLE, &device->dev_state) ||
			    test_bit(BTRFS_DEV_STATE_MISSING, &device->dev_state))
				continue;
			/*
			 * Read once: the NULL check and the reference must see
			 * the same pointer.  btrfs_close_one_device() clears
			 * this field, and nothing here holds device_list_mutex
			 * against it, so re-reading it -- or letting the
			 * compiler do so -- would allow get_file(NULL).
			 */
			bdev_file = READ_ONCE(device->bdev_file);
			if (!bdev_file)
				continue;
			slots[nr] = READ_ONCE(device->wib_next_slot) % BTRFS_WIB_NR_SLOTS;
			files[nr++] = get_file(bdev_file);
		}
		rcu_read_unlock();

		if (nr < capacity)
			break;
		/* Devices were added meanwhile, retry with a larger array. */
		for (int i = 0; i < nr; i++)
			fput(files[i]);
		kfree(files);
		kfree(slots);
	}
	*files_ret = files;
	*slots_ret = slots;
	*nr_ret = nr;
	return 0;
}

/*
 * After a commit: advance the slot of every device that got the block, and
 * account the failed writes.  Devices removed meanwhile are simply skipped.
 */
static void wib_update_targets(struct btrfs_fs_info *fs_info, struct file **files,
			       const unsigned int *slots, const bool *ok, int nr)
{
	struct btrfs_device *device;

	rcu_read_lock();
	list_for_each_entry_rcu(device, &fs_info->fs_devices->devices, dev_list) {
		for (int i = 0; i < nr; i++) {
			if (device->bdev != file_bdev(files[i]))
				continue;
			if (ok[i])
				WRITE_ONCE(device->wib_next_slot,
					   (slots[i] + 1) % BTRFS_WIB_NR_SLOTS);
			else
				btrfs_dev_stat_inc_and_print(device,
							     BTRFS_DEV_STAT_WRITE_ERRS);
			break;
		}
	}
	rcu_read_unlock();
}

/* Submit @bio to every target and wait; return the number of failures. */
static int wib_submit_all_devices(struct btrfs_wib *wib, blk_opf_t opf, bool with_data,
				  int *nr_ret)
{
	struct btrfs_fs_info *fs_info = wib->fs_info;
	struct page *page = virt_to_page(wib->block);
	struct file **files = NULL;
	unsigned int *slots = NULL;
	struct bio **bios;
	bool *ok;
	int nr = 0;
	int nr_errors = 0;
	int ret;

	*nr_ret = 0;
	ret = wib_collect_targets(fs_info, &files, &slots, &nr);
	if (ret < 0)
		return ret;
	*nr_ret = nr;
	if (nr == 0) {
		kfree(files);
		kfree(slots);
		return 0;
	}
	bios = kcalloc(nr, sizeof(*bios), GFP_NOFS);
	ok = kcalloc(nr, sizeof(*ok), GFP_NOFS);
	if (!bios || !ok) {
		ret = -ENOMEM;
		goto out;
	}

	atomic_set(&wib->io_pending, 1);
	for (int i = 0; i < nr; i++) {
		struct bio *bio;

		bio = bio_alloc(file_bdev(files[i]), with_data ? 1 : 0, opf, GFP_NOFS);
		bio->bi_private = wib;
		bio->bi_end_io = wib_write_end_io;
		if (with_data) {
			bio->bi_iter.bi_sector = (BTRFS_WIB_OFFSET +
						  slots[i] * BTRFS_WIB_SLOT_SIZE) >> SECTOR_SHIFT;
			__bio_add_page(bio, page, BTRFS_WIB_SLOT_SIZE, 0);
		}
		bios[i] = bio;
		atomic_inc(&wib->io_pending);
		submit_bio(bio);
	}
	if (!atomic_dec_and_test(&wib->io_pending))
		wait_event(wib->io_wait, atomic_read(&wib->io_pending) == 0);

	for (int i = 0; i < nr; i++) {
		ok[i] = bios[i]->bi_status == BLK_STS_OK;
		if (!ok[i]) {
			nr_errors++;
			btrfs_warn_rl(fs_info,
				"raid56 write-intent log %s failed on %pg: %d",
				with_data ? "write" : "flush", bios[i]->bi_bdev,
				blk_status_to_errno(bios[i]->bi_status));
		}
		bio_put(bios[i]);
	}
	if (with_data)
		wib_update_targets(fs_info, files, slots, ok, nr);
	ret = nr_errors;
out:
	kfree(ok);
	kfree(bios);
	for (int i = 0; i < nr; i++)
		fput(files[i]);
	kfree(files);
	kfree(slots);
	return ret;
}

/*
 * Flush the write cache of every writable device.  Return true if every
 * device confirmed the flush (or barriers are disabled).
 */
static bool wib_flush_all_devices(struct btrfs_wib *wib)
{
	int nr;
	int ret;

	if (btrfs_test_opt(wib->fs_info, NOBARRIER))
		return true;
	atomic64_inc(&wib->stat_commit_flushes);
	ret = wib_submit_all_devices(wib, REQ_OP_WRITE | REQ_PREFLUSH | REQ_SYNC, false, &nr);
	return ret == 0;
}

/*
 * Write wib->block to the next slot of every writable device (FUA) and
 * wait.
 *
 * @nr_errors_ret receives the number of devices that failed the write.
 * Return 0 when enough copies were written for the block to survive the
 * tolerated number of device failures, -EIO otherwise.
 */
static int wib_write_all_devices(struct btrfs_wib *wib, int *nr_errors_ret)
{
	struct btrfs_fs_info *fs_info = wib->fs_info;
	blk_opf_t opf = REQ_OP_WRITE | REQ_SYNC | REQ_META | REQ_PRIO;
	int nr_errors;
	int nr;
	int ret;

	*nr_errors_ret = 0;
	if (!btrfs_test_opt(fs_info, NOBARRIER))
		opf |= REQ_FUA;

	ret = wib_submit_all_devices(wib, opf, true, &nr);
	if (ret < 0)
		return ret;
	nr_errors = ret;
	*nr_errors_ret = nr_errors;
	if (nr_errors == 0)
		return 0;

	/*
	 * The block must be on enough devices that after losing the
	 * tolerated number of devices at least one copy remains.
	 */
	if (nr - nr_errors >= wib_max_tolerated_failures(fs_info) + 1) {
		btrfs_warn_rl(fs_info,
		"raid56 write-intent log: %d of %d device writes failed, continuing",
			      nr_errors, nr);
		return 0;
	}
	btrfs_err_rl(fs_info,
	"raid56 write-intent log: %d of %d device writes failed, not enough copies",
		     nr_errors, nr);
	return -EIO;
}

/*
 * A commit is about to drop the stripes the last block lists but the
 * in-memory set does not, and some device did not confirm the flush of its
 * cache: that device may hold their data unflushed, so a block that no
 * longer lists them must not be written.  Keep them as error records (a
 * device may end up with stale sectors); they are scrubbed at the next
 * mount.
 */
static void wib_readd_dropped(struct btrfs_wib *wib)
{
	const struct btrfs_wib_disk_header *oh = wib->last;
	const struct btrfs_wib_disk_entry *oe = wib->last + sizeof(*oh);
	const u32 onr = le32_to_cpu(oh->nr_entries);
	unsigned int nr_readded = 0;
	unsigned int nr_lost = 0;

	lockdep_assert_held(&wib->commit_mutex);

	if (le64_to_cpu(oh->magic) != BTRFS_WIB_MAGIC)
		return;

	spin_lock(&wib->lock);
	for (u32 i = 0; i < onr; i++) {
		const u64 bytenr = le64_to_cpu(oe[i].bytenr);
		u64 bits = wib_disk_entry_bits(&oe[i]);
		struct btrfs_wib_entry *e;

		e = wib_find_entry(wib, bytenr);
		if (e)
			bits &= ~(e->bitmap | e->sticky);
		if (!bits)
			continue;
		if (!e)
			e = wib_find_or_alloc_entry(wib, bytenr, false);
		if (!e) {
			nr_lost += hweight64(bits);
			continue;
		}
		e->sticky |= bits;
		nr_readded += hweight64(bits);
	}
	spin_unlock(&wib->lock);

	if (nr_readded)
		atomic64_add(nr_readded, &wib->stat_sticky);
	if (btrfs_is_testing(wib->fs_info))
		return;
	if (nr_readded)
		btrfs_warn_rl(wib->fs_info,
	"raid56 write-intent log: keeping %u stripes recorded, a device did not confirm their data is flushed",
			      nr_readded);
	if (nr_lost)
		btrfs_warn_rl(wib->fs_info,
	"raid56 write-intent log full, %u stripes whose flush a device did not confirm are not recorded, run scrub",
			      nr_lost);
}

/*
 * Build wib->block from the in-memory set plus everything @base lists, and
 * write it.  -ENOSPC if that does not fit in a block (nothing is written).
 * commit_mutex must be held.
 */
static int wib_write_block_locked(struct btrfs_wib *wib, u64 seq, const void *base,
				  bool force)
{
	struct btrfs_wib_disk_header *hdr = wib->block;
	struct btrfs_wib_disk_header *last = wib->last;
	int nr_errors;
	int ret;

	lockdep_assert_held(&wib->commit_mutex);

	ret = btrfs_wib_build_block(wib, wib->block, seq, base);
	if (ret < 0)
		return ret;

	/*
	 * Nothing changed since the last commit and that one reached every
	 * device: the set is already durable, no IO needed.
	 */
	if (!force && wib->last_ok &&
	    le64_to_cpu(last->magic) == BTRFS_WIB_MAGIC &&
	    le32_to_cpu(last->nr_entries) == le32_to_cpu(hdr->nr_entries) &&
	    memcmp(wib->last + sizeof(*hdr), wib->block + sizeof(*hdr),
		   le32_to_cpu(hdr->nr_entries) * sizeof(struct btrfs_wib_disk_entry)) == 0)
		goto done;

	ret = wib_write_all_devices(wib, &nr_errors);
	if (nr_errors || ret < 0)
		atomic64_inc(&wib->stat_commit_errors);
	/*
	 * Whether or not the write succeeded, this is the block every device
	 * either has or has an older subset of; the next union is built on it.
	 */
	memcpy(wib->last, wib->block, BTRFS_WIB_SLOT_SIZE);
	wib->last_ok = (ret == 0 && nr_errors == 0);
	if (ret < 0)
		return ret;
	atomic64_inc(&wib->stat_commits);
done:
	spin_lock(&wib->lock);
	wib->seq = seq;
	spin_unlock(&wib->lock);
	wake_up_all(&wib->wait);
	return 0;
}

/*
 * Write a block that drops the stripes that finished before @snapshot was
 * taken, the devices having been flushed after that (@flushed: every
 * device confirmed).  A stripe that finished after the snapshot may have
 * completed its writes during the flush, so it stays listed.
 *
 * If a device did not confirm the flush nothing is dropped: the block is
 * the union with the last one, and the stripes that would have been
 * dropped become error records (that device may hold stale sectors).
 */
static int wib_drop_locked(struct btrfs_wib *wib, u64 seq, const void *snapshot,
			   bool flushed, bool force)
{
	lockdep_assert_held(&wib->commit_mutex);

	if (!flushed) {
		wib_readd_dropped(wib);
		return wib_write_block_locked(wib, seq, wib->last, force);
	}
	return wib_write_block_locked(wib, seq, snapshot, force);
}

/*
 * Flush every device and drop the stripes that finished before the flush.
 * Retried a few times if stripes turned over during the flush faster than
 * a block can hold.
 */
static int wib_flush_and_drop_locked(struct btrfs_wib *wib, u64 seq, bool force)
{
	int ret = -ENOSPC;

	lockdep_assert_held(&wib->commit_mutex);

	for (int i = 0; i < 3 && ret == -ENOSPC; i++) {
		bool flushed;

		/*
		 * Build into wib->flushsnap.  Not wib->prepared: that holds the
		 * snapshot a transaction commit took before its barriers, and
		 * the commit drops against it on the strength of those
		 * barriers, so replacing it here with a snapshot taken after
		 * them would let that commit drop a stripe no flush covered.
		 * And not wib->block either: wib_drop_locked() hands the
		 * snapshot to wib_write_block_locked(), which builds into
		 * wib->block and memsets it first -- the snapshot would be
		 * zeroed before it was read, silently contributing nothing,
		 * and the block written would then omit every stripe that
		 * finished during the flush.
		 */
		ret = btrfs_wib_build_block(wib, wib->flushsnap, seq, NULL);
		/* The in-memory set always fits. */
		ASSERT(ret == 0);
		flushed = wib_flush_all_devices(wib);
		ret = wib_drop_locked(wib, seq, wib->flushsnap, flushed, force);
	}
	return ret;
}

/*
 * Take a snapshot of the in-flight set and persist it, adding to the last
 * block (which needs no flush) if that fits, else flushing and dropping.
 * commit_mutex must be held.
 */
static int wib_commit_locked(struct btrfs_wib *wib, bool force)
{
	u64 seq;
	int ret;

	lockdep_assert_held(&wib->commit_mutex);

	spin_lock(&wib->lock);
	seq = ++wib->snap_seq;
	spin_unlock(&wib->lock);

	/*
	 * A transaction commit is between its snapshot and its barriers (or
	 * past them): a stripe recorded now may write during or after the
	 * flush, so it must not be dropped by that commit even if it finishes
	 * before then.  Add the current set to the snapshot.
	 */
	if (wib->prepared_valid) {
		ret = btrfs_wib_build_block(wib, wib->block, 0, wib->prepared);
		if (ret == 0)
			memcpy(wib->prepared, wib->block, BTRFS_WIB_SLOT_SIZE);
		else
			wib->prepared_valid = false;
	}

	ret = wib_write_block_locked(wib, seq, wib->last, force);
	if (ret == -ENOSPC)
		ret = wib_flush_and_drop_locked(wib, seq, force);
	return ret;
}

/*
 * Wait until a commit with sequence number >= @want has completed.  The
 * commits issued here only add to the on-disk block, so they need no
 * flush.
 */
static int wib_commit_wait(struct btrfs_wib *wib, u64 want)
{
	int ret = 0;

	mutex_lock(&wib->commit_mutex);
	while (true) {
		u64 seq;

		spin_lock(&wib->lock);
		seq = wib->seq;
		spin_unlock(&wib->lock);
		if (seq >= want)
			break;
		ret = wib_commit_locked(wib, false);
		if (ret < 0)
			break;
	}
	mutex_unlock(&wib->commit_mutex);
	return ret;
}

/*
 * Record that a sub-stripe (or in-place) write of the full stripe covering
 * [@logical, @logical + @len) is about to be submitted.
 *
 * Returns only after the record is durable on the devices (or immediately
 * if the log is not enabled).  Must not be called with locks held that the
 * commit path or device IO completion could depend on.  On failure nothing
 * stays recorded and the caller must not write.
 */
int btrfs_wib_mark(struct btrfs_fs_info *fs_info, u64 logical, u64 len)
{
	struct btrfs_wib *wib = fs_info->wib;
	bool enabled;
	u64 want;
	int ret;

	if (!wib)
		return 0;
	ASSERT(len > 0);

	/* Full stripes are 64K aligned; be safe against any other caller. */
	len = round_up(logical + len, BTRFS_WIB_BLOCK_SIZE);
	logical = round_down(logical, BTRFS_WIB_BLOCK_SIZE);
	len -= logical;

	while (true) {
		spin_lock(&wib->lock);
		ret = btrfs_wib_try_mark(wib, logical, len);
		if (ret == 0) {
			/*
			 * The next snapshot is guaranteed to contain our
			 * bits, wait for the commit that writes it.
			 */
			want = wib->snap_seq + 1;
			enabled = wib->enabled;
			spin_unlock(&wib->lock);
			break;
		}
		spin_unlock(&wib->lock);

		/*
		 * Log full.  Entries are freed when in-flight RMWs finish.
		 * Those RMWs can themselves be waiting on commit_mutex and on
		 * IO to devices this one knows nothing about, so this is not
		 * a wait that is guaranteed to end: bound it and fail the
		 * write rather than hang the task forever.
		 */
		btrfs_warn_rl(fs_info,
			      "raid56 write-intent log full, waiting for in-flight writes");
		if (!wait_event_timeout(wib->wait,
					btrfs_wib_can_mark(wib, logical, len),
					BTRFS_WIB_FULL_TIMEOUT)) {
			btrfs_err_rl(fs_info,
	"raid56 write-intent log still full after %u seconds, failing the write",
				     jiffies_to_msecs(BTRFS_WIB_FULL_TIMEOUT) / 1000);
			return -EIO;
		}
	}
	atomic64_inc(&wib->stat_marks);

	if (!enabled)
		return 0;
	ret = wib_commit_wait(wib, want);
	if (ret < 0) {
		/* Nothing will be written, don't leave the bits in flight. */
		btrfs_wib_done(fs_info, logical, len, false);
	}
	return ret;
}

/*
 * All writes of the RMW recorded by btrfs_wib_mark() have completed.
 *
 * @failed: at least one of them failed (device error or missing device).
 * The stripe is then inconsistent on that device without any crash; keep it
 * logged so that it is scrubbed once the device is back, replaced or
 * dropped, at the next mount.
 */
void btrfs_wib_done(struct btrfs_fs_info *fs_info, u64 logical, u64 len, bool failed)
{
	struct btrfs_wib *wib = fs_info->wib;
	u64 end;
	bool freed = false;

	if (!wib)
		return;

	end = round_up(logical + len, BTRFS_WIB_BLOCK_SIZE);
	logical = round_down(logical, BTRFS_WIB_BLOCK_SIZE);
	len = end - logical;

	spin_lock(&wib->lock);
	for (u64 cur = wib_entry_bytenr(logical); cur < end; cur += BTRFS_WIB_ENTRY_SIZE) {
		struct btrfs_wib_entry *e = wib_find_entry(wib, cur);
		u64 mask;

		if (!e)
			continue;
		mask = btrfs_wib_range_mask(cur, logical, len);
		e->bitmap &= ~mask;
		if (failed) {
			e->sticky |= mask;
			atomic64_inc(&wib->stat_sticky);
		}
		if (!e->bitmap)
			freed = true;
	}
	spin_unlock(&wib->lock);
	if (freed)
		wake_up_all(&wib->wait);
}

/*
 * Keep [@logical, @logical + @len) recorded across mounts without a write in
 * flight: used for stripes whose recovery could not complete.  Dropped with
 * a warning if the log is full.
 */
void btrfs_wib_add_sticky(struct btrfs_fs_info *fs_info, u64 logical, u64 len)
{
	struct btrfs_wib *wib = fs_info->wib;
	int ret;

	if (!wib)
		return;

	spin_lock(&wib->lock);
	ret = btrfs_wib_try_mark(wib, logical, len);
	spin_unlock(&wib->lock);
	if (ret < 0) {
		btrfs_warn(fs_info,
	"raid56 write-intent log full, cannot keep full stripe at %llu for the next mount, run scrub once all devices are present",
			   logical);
		return;
	}
	btrfs_wib_done(fs_info, logical, len, true);
}

/* [@logical, @logical + @len) was fully recovered, forget its error record. */
void btrfs_wib_clear_sticky(struct btrfs_fs_info *fs_info, u64 logical, u64 len)
{
	struct btrfs_wib *wib = fs_info->wib;
	const u64 end = logical + len;
	bool freed = false;

	if (!wib)
		return;

	spin_lock(&wib->lock);
	for (u64 cur = wib_entry_bytenr(logical); cur < end; cur += BTRFS_WIB_ENTRY_SIZE) {
		struct btrfs_wib_entry *e = wib_find_entry(wib, cur);

		if (!e)
			continue;
		e->sticky &= ~btrfs_wib_range_mask(cur, logical, len);
		if (!wib_entry_used(e))
			freed = true;
	}
	spin_unlock(&wib->lock);
	if (freed)
		wake_up_all(&wib->wait);
}

/*
 * Called at transaction commit (and log commit) time, before the device
 * barriers: snapshot the in-flight set, so that btrfs_wib_commit() only
 * drops the stripes that finished before the barriers were issued.
 */
void btrfs_wib_commit_prepare(struct btrfs_fs_info *fs_info)
{
	struct btrfs_wib *wib = fs_info->wib;
	int ret;

	if (!wib)
		return;
	mutex_lock(&wib->commit_mutex);
	ret = btrfs_wib_build_block(wib, wib->prepared, 0, NULL);
	ASSERT(ret == 0);
	wib->prepared_valid = true;
	mutex_unlock(&wib->commit_mutex);
}

/*
 * Overwrite @nr_slots of every device with the current in-memory set, each
 * write preceded by a flush.  Writing every slot leaves no older block behind
 * that a later mount could pick as the newest one; writing a single slot is
 * enough when only the newest block matters.
 */
static int wib_persist_all_slots(struct btrfs_wib *wib, int nr_slots)
{
	int ret = 0;

	mutex_lock(&wib->commit_mutex);
	for (int i = 0; i < nr_slots; i++) {
		u64 seq;

		spin_lock(&wib->lock);
		seq = ++wib->snap_seq;
		spin_unlock(&wib->lock);
		ret = wib_flush_and_drop_locked(wib, seq, true);
		if (ret < 0)
			break;
	}
	mutex_unlock(&wib->commit_mutex);
	if (ret < 0)
		btrfs_err(wib->fs_info,
			  "raid56 write-intent log: failed to write the log: %d",
			  ret);
	return ret;
}

/*
 * Called at transaction commit (and log commit) time, after the device
 * barriers and before the superblocks are written.  Persists the current
 * in-flight set, dropping stripes that finished before the snapshot taken
 * by btrfs_wib_commit_prepare() (@flushed: every device confirmed the
 * barrier), handles an enable requested from a context that could not do
 * IO itself, and a pending disable.
 */
int btrfs_wib_commit(struct btrfs_fs_info *fs_info, bool flushed)
{
	struct btrfs_wib *wib = fs_info->wib;
	bool enabled;
	bool enable;
	bool disable;
	u64 seq;
	int ret;

	if (!wib)
		return 0;

	spin_lock(&wib->lock);
	enabled = wib->enabled;
	enable = wib->enable_requested;
	disable = wib->disable_requested;
	/*
	 * Tell a concurrent btrfs_wib_disable() that an enable it cannot see
	 * in wib->enabled is under way, so that it is not lost between here
	 * and the re-check below.
	 */
	if (enable)
		wib->enable_in_progress = true;
	spin_unlock(&wib->lock);

	if (enable) {
		/*
		 * The feature flag was set in the in-memory superblock with
		 * the request and is written by this commit; the log must be
		 * durable before that, so a failure has to fail the commit.
		 */
		ret = btrfs_wib_enable(fs_info);
		spin_lock(&wib->lock);
		wib->enable_in_progress = false;
		disable = wib->disable_requested;
		spin_unlock(&wib->lock);
		if (ret)
			return ret;
		/*
		 * A disable that arrived while the log was being written out
		 * already cleared the flag from the in-memory superblock.
		 * Setting it again here would make this commit persist a
		 * feature the administrator was told had been turned off; the
		 * log stays enabled for one commit and the disable completes
		 * at the next one, as it does in the ordinary case.
		 */
		if (!disable)
			btrfs_set_fs_compat_ro(fs_info, RAID56_WRITE_INTENT);
		return 0;
	}
	if (!enabled)
		return 0;

	if (disable) {
		/*
		 * Keep persisting until a superblock without the flag has been
		 * written: this commit's superblock lacks it, the next commit
		 * knows it is durable.
		 */
		const bool flag_written = btrfs_super_compat_ro_flags(fs_info->super_for_commit) &
					  BTRFS_FEATURE_COMPAT_RO_RAID56_WRITE_INTENT;

		spin_lock(&wib->lock);
		if (!flag_written && wib->disable_armed) {
			wib->enabled = false;
			wib->disable_requested = false;
			wib->disable_armed = false;
			spin_unlock(&wib->lock);
			/*
			 * Nothing refreshes the log from here on, so whatever
			 * block the devices carry is the one they keep -- and
			 * it lists the stripes that were in flight at some
			 * earlier commit, which have long since completed.
			 * The next mount reads it (btrfs_wib_load() does not
			 * look at the feature flag) and scrubs every stripe
			 * in it, so leaving a stale block turns a disable
			 * into a slow mount later on, for stripes that are
			 * fine.  Write the current set once instead: the
			 * writes still in flight, and the stripes recorded as
			 * damaged, which do want that scrub.
			 */
			ret = wib_persist_all_slots(wib, BTRFS_WIB_NR_SLOTS);
			if (ret < 0)
				btrfs_warn(fs_info,
	"raid56 write-intent log: could not write the final log block, the next mount will scrub the stripes the previous one listed");
			if (!btrfs_is_testing(fs_info))
				btrfs_info(fs_info, "raid56 write-intent log disabled");
			return 0;
		}
		wib->disable_armed = !flag_written;
		spin_unlock(&wib->lock);
	}

	mutex_lock(&wib->commit_mutex);
	spin_lock(&wib->lock);
	seq = ++wib->snap_seq;
	spin_unlock(&wib->lock);
	if (!wib->prepared_valid) {
		/* No snapshot before the flush: don't trust it, drop nothing. */
		ret = btrfs_wib_build_block(wib, wib->prepared, 0, NULL);
		ASSERT(ret == 0);
		flushed = false;
	}
	wib->prepared_valid = false;
	ret = wib_drop_locked(wib, seq, wib->prepared, flushed, false);
	mutex_unlock(&wib->commit_mutex);
	if (ret == -ENOSPC) {
		/*
		 * Not even the union fits; the devices keep their current
		 * blocks, which list everything that may be in flight.
		 */
		btrfs_warn_rl(fs_info,
			      "raid56 write-intent log: block full, keeping the previous one");
	} else if (ret < 0) {
		/*
		 * A failed lazy commit only means that stale entries remain on
		 * the devices that didn't get the new block; recovery is a
		 * superset then, which is safe.  RMWs waiting for their own
		 * record retry the commit and fail on their own if it keeps
		 * failing.  Nothing to abort the transaction for.
		 */
		btrfs_warn_rl(fs_info,
			      "raid56 write-intent log: lazy commit failed: %d", ret);
	}
	return 0;
}

/*
 * Start persisting the log.  Everything currently in flight is written out
 * with a flush before this returns, so that a crash right after the feature
 * flag becomes durable is covered.
 */
int btrfs_wib_enable(struct btrfs_fs_info *fs_info)
{
	struct btrfs_wib *wib = fs_info->wib;
	bool was_enabled;
	u64 seq;
	int ret;

	if (!wib)
		return -EOPNOTSUPP;
	if (btrfs_is_zoned(fs_info))
		return -EOPNOTSUPP;

	mutex_lock(&wib->commit_mutex);
	spin_lock(&wib->lock);
	was_enabled = wib->enabled;
	wib->enabled = true;
	wib->enable_requested = false;
	/*
	 * Only a disable this enable supersedes is cancelled.  One raised
	 * against this very enable (enable_in_progress) has to survive: the
	 * caller re-checks it and leaves the feature flag clear.
	 */
	if (!wib->enable_in_progress) {
		wib->disable_requested = false;
		wib->disable_armed = false;
	}
	spin_unlock(&wib->lock);

	spin_lock(&wib->lock);
	seq = ++wib->snap_seq;
	spin_unlock(&wib->lock);
	ret = wib_flush_and_drop_locked(wib, seq, true);
	if (ret < 0 && !was_enabled) {
		spin_lock(&wib->lock);
		wib->enabled = false;
		spin_unlock(&wib->lock);
	}
	mutex_unlock(&wib->commit_mutex);

	if (ret == 0 && !was_enabled && !btrfs_is_testing(fs_info))
		btrfs_info(fs_info, "raid56 write-intent log enabled");
	return ret;
}

/*
 * Stop persisting the log once the superblock without the feature flag is
 * durable (see btrfs_wib_commit()).  Until then the log is maintained: a
 * crash before that superblock lands would be recovered with the log by a
 * kernel that sees the flag.
 */
void btrfs_wib_disable(struct btrfs_fs_info *fs_info)
{
	struct btrfs_wib *wib = fs_info->wib;

	if (!wib)
		return;
	spin_lock(&wib->lock);
	wib->enable_requested = false;
	if (wib->enabled || wib->enable_in_progress) {
		wib->disable_requested = true;
		wib->disable_armed = false;
	}
	spin_unlock(&wib->lock);
	if (!btrfs_is_testing(fs_info))
		btrfs_info(fs_info,
			   "raid56 write-intent log will be disabled after the next commit");
}

/*
 * Set the feature flag (so that it goes out with this transaction's
 * superblock) and request the log to be enabled at that commit, before the
 * superblock is written.  The two become durable together: btrfs_wib_commit()
 * writes the log out first and a failure there aborts the commit, so the flag
 * never promises a log that is not there.
 *
 * @automatic is set by the filesystem enabling the log by itself (the first
 * RAID56 chunk), and clear when an administrator asked for it.
 *
 * Nothing here does device IO, because none of the callers can afford it.
 * Chunk allocation holds chunk_mutex.  A sysfs store holds the kernfs node
 * active for as long as it runs, so an enable that waited on a wedged device
 * would hold off the removal of that node -- and therefore unmount -- with no
 * way to interrupt it.  The commit path has neither problem.
 */
int btrfs_wib_request_enable(struct btrfs_fs_info *fs_info, bool automatic)
{
	struct btrfs_wib *wib = fs_info->wib;

	if (!wib)
		return -EOPNOTSUPP;
	if (btrfs_is_zoned(fs_info))
		return -EOPNOTSUPP;
	/*
	 * noraid56_write_intent suppresses the log being turned on by the
	 * filesystem itself; it does not overrule an administrator asking for
	 * it through sysfs or the ioctl.
	 */
	if (automatic && btrfs_test_opt(fs_info, NORAID56_WRITE_INTENT))
		return -EOPNOTSUPP;

	spin_lock(&wib->lock);
	if (!wib->enabled)
		wib->enable_requested = true;
	/*
	 * A disable that has not taken effect yet is cancelled: the flag is
	 * about to be set again, which is what disable_armed waits to see
	 * gone.
	 */
	wib->disable_requested = false;
	wib->disable_armed = false;
	spin_unlock(&wib->lock);
	btrfs_set_fs_compat_ro(fs_info, RAID56_WRITE_INTENT);
	return 0;
}

int btrfs_wib_alloc(struct btrfs_fs_info *fs_info)
{
	struct btrfs_wib *wib;

	ASSERT(!fs_info->wib);

	wib = kzalloc_obj(*wib, GFP_KERNEL);
	if (!wib)
		return -ENOMEM;
	wib->block = (void *)get_zeroed_page(GFP_KERNEL);
	wib->last = (void *)get_zeroed_page(GFP_KERNEL);
	wib->prepared = (void *)get_zeroed_page(GFP_KERNEL);
	wib->flushsnap = (void *)get_zeroed_page(GFP_KERNEL);
	if (!wib->block || !wib->last || !wib->prepared || !wib->flushsnap) {
		free_page((unsigned long)wib->block);
		free_page((unsigned long)wib->last);
		free_page((unsigned long)wib->prepared);
		free_page((unsigned long)wib->flushsnap);
		kfree(wib);
		return -ENOMEM;
	}
	wib->fs_info = fs_info;
	spin_lock_init(&wib->lock);
	mutex_init(&wib->commit_mutex);
	init_waitqueue_head(&wib->wait);
	init_waitqueue_head(&wib->io_wait);
	atomic_set(&wib->io_pending, 0);
	fs_info->wib = wib;
	return 0;
}

void btrfs_wib_free(struct btrfs_fs_info *fs_info)
{
	struct btrfs_wib *wib = fs_info->wib;

	if (!wib)
		return;
	fs_info->wib = NULL;
	free_page((unsigned long)wib->block);
	free_page((unsigned long)wib->last);
	free_page((unsigned long)wib->prepared);
	free_page((unsigned long)wib->flushsnap);
	kvfree(wib->pending);
	kfree(wib);
}

/* Append a region to the pending recovery list (merged later). */
int btrfs_wib_add_pending(struct btrfs_wib *wib, u64 bytenr, u64 bitmap, u64 error)
{
	if (!bitmap && !error)
		return 0;
	if (wib->nr_pending == wib->max_pending) {
		unsigned int new_max = wib->max_pending ? wib->max_pending * 2 : 256;
		struct btrfs_wib_entry *p;

		p = kvmalloc_array(new_max, sizeof(*p), GFP_KERNEL);
		if (!p)
			return -ENOMEM;
		if (wib->pending)
			memcpy(p, wib->pending, wib->nr_pending * sizeof(*p));
		kvfree(wib->pending);
		wib->pending = p;
		wib->max_pending = new_max;
	}
	wib->pending[wib->nr_pending].bytenr = bytenr;
	wib->pending[wib->nr_pending].bitmap = bitmap;
	wib->pending[wib->nr_pending].sticky = error;
	wib->nr_pending++;
	return 0;
}

static int wib_pending_cmp(const void *a, const void *b)
{
	const struct btrfs_wib_entry *ea = a;
	const struct btrfs_wib_entry *eb = b;

	if (ea->bytenr < eb->bytenr)
		return -1;
	if (ea->bytenr > eb->bytenr)
		return 1;
	return 0;
}

/* Sort the pending list and merge entries of the same region. */
void btrfs_wib_finalize_pending(struct btrfs_wib *wib)
{
	unsigned int out = 0;

	if (wib->nr_pending == 0)
		return;
	sort(wib->pending, wib->nr_pending, sizeof(*wib->pending), wib_pending_cmp, NULL);
	for (unsigned int i = 0; i < wib->nr_pending; i++) {
		if (out && wib->pending[out - 1].bytenr == wib->pending[i].bytenr) {
			wib->pending[out - 1].bitmap |= wib->pending[i].bitmap;
			wib->pending[out - 1].sticky |= wib->pending[i].sticky;
			continue;
		}
		wib->pending[out++] = wib->pending[i];
	}
	wib->nr_pending = out;
}

static int wib_read_slot(struct btrfs_device *device, unsigned int slot, void *buf)
{
	struct bio *bio;
	int ret;

	bio = bio_alloc(device->bdev, 1, REQ_OP_READ | REQ_META | REQ_PRIO, GFP_KERNEL);
	bio->bi_iter.bi_sector = (BTRFS_WIB_OFFSET + slot * BTRFS_WIB_SLOT_SIZE) >>
				 SECTOR_SHIFT;
	__bio_add_page(bio, virt_to_page(buf), BTRFS_WIB_SLOT_SIZE, offset_in_page(buf));
	ret = submit_bio_wait(bio);
	bio_put(bio);
	return ret;
}

/*
 * Read the log blocks of all present devices and build the list of full
 * stripes to recover before the filesystem is written to.  Called at mount
 * before any write happens.
 *
 * Per device only the newest valid block counts: a block with sequence
 * number N on a device was written with a PREFLUSH to that device whenever
 * it dropped a stripe listed by N-1, so everything the older block lists
 * and the newer one doesn't is on stable media on that device.  Across
 * devices the union is taken: a device that missed a commit (torn write,
 * IO error, or absent at the time) still lists the stripes that commit
 * dropped, and scrubbing a consistent stripe is harmless.
 */
int btrfs_wib_load(struct btrfs_fs_info *fs_info)
{
	struct btrfs_wib *wib = fs_info->wib;
	struct btrfs_fs_devices *fs_devices = fs_info->fs_devices;
	struct btrfs_device *device;
	u64 max_seq = 0;
	unsigned int nr_valid = 0;
	unsigned int nofs_flag;
	void *buf;
	int ret = 0;

	if (!wib)
		return 0;
	if (btrfs_is_zoned(fs_info))
		return 0;

	buf = (void *)get_zeroed_page(GFP_KERNEL);
	if (!buf)
		return -ENOMEM;

	/* Allocations under device_list_mutex must not enter reclaim. */
	nofs_flag = memalloc_nofs_save();
	mutex_lock(&fs_devices->device_list_mutex);
	list_for_each_entry(device, &fs_devices->devices, dev_list) {
		const struct btrfs_wib_disk_header *hdr = buf;
		const struct btrfs_wib_disk_entry *de = buf + sizeof(*hdr);
		u64 dev_seq = 0;
		int dev_slot = -1;
		u32 nr;

		device->wib_next_slot = 0;
		if (!device->bdev)
			continue;
		if (!test_bit(BTRFS_DEV_STATE_IN_FS_METADATA, &device->dev_state))
			continue;

		/* Find the newest valid block of this device. */
		for (unsigned int slot = 0; slot < BTRFS_WIB_NR_SLOTS; slot++) {
			ret = wib_read_slot(device, slot, buf);
			if (ret < 0) {
				btrfs_warn(fs_info,
			"raid56 write-intent log: failed to read slot %u of %s: %d",
					   slot, btrfs_dev_name(device), ret);
				btrfs_dev_stat_inc_and_print(device, BTRFS_DEV_STAT_READ_ERRS);
				ret = 0;
				continue;
			}
			if (!btrfs_wib_block_valid(fs_info, buf))
				continue;
			nr_valid++;
			if (dev_slot < 0 || le64_to_cpu(hdr->seq) > dev_seq) {
				dev_seq = le64_to_cpu(hdr->seq);
				dev_slot = slot;
			}
		}
		if (dev_slot < 0)
			continue;
		/* Don't overwrite the newest block of this device first. */
		device->wib_next_slot = (dev_slot + 1) % BTRFS_WIB_NR_SLOTS;
		if (dev_seq > max_seq)
			max_seq = dev_seq;

		ret = wib_read_slot(device, dev_slot, buf);
		if (ret < 0 || !btrfs_wib_block_valid(fs_info, buf)) {
			/* Read it fine a moment ago, treat as an IO error. */
			btrfs_warn(fs_info,
			"raid56 write-intent log: failed to re-read slot %d of %s",
				   dev_slot, btrfs_dev_name(device));
			ret = 0;
			continue;
		}
		nr = le32_to_cpu(hdr->nr_entries);
		for (u32 i = 0; i < nr; i++) {
			ret = btrfs_wib_add_pending(wib, le64_to_cpu(de[i].bytenr),
						    le64_to_cpu(de[i].bitmap),
						    le64_to_cpu(de[i].error));
			if (ret < 0)
				goto out;
		}
	}
out:
	mutex_unlock(&fs_devices->device_list_mutex);
	memalloc_nofs_restore(nofs_flag);
	free_page((unsigned long)buf);
	if (ret < 0)
		return ret;

	btrfs_wib_finalize_pending(wib);

	/* Continue the sequence. */
	wib->seq = max_seq;
	wib->snap_seq = max_seq;

	if (wib->nr_pending) {
		unsigned int nr_blocks = 0;
		unsigned int nr_error = 0;

		for (unsigned int i = 0; i < wib->nr_pending; i++) {
			nr_blocks += hweight64(wib->pending[i].bitmap | wib->pending[i].sticky);
			nr_error += hweight64(wib->pending[i].sticky);
		}
		btrfs_info(fs_info,
	"raid56 write-intent log: %u valid blocks found, %u regions with %u dirty stripes to recover (%u with earlier errors)",
			   nr_valid, wib->nr_pending, nr_blocks, nr_error);
	}
	return 0;
}

/* True if any pending error record covers [@start, @start + @len). */
static bool wib_pending_has_error(struct btrfs_wib *wib, u64 start, u64 len)
{
	for (unsigned int i = 0; i < wib->nr_pending; i++) {
		const struct btrfs_wib_entry *e = &wib->pending[i];

		if (e->sticky & btrfs_wib_range_mask(e->bytenr, start, len))
			return true;
	}
	return false;
}

struct wib_recovery_stats {
	unsigned int done;
	unsigned int skipped;
	unsigned int failed;
	unsigned int kept;
};

/*
 * Scrub the full stripe containing @logical.
 *
 * @trusted: the sectors that cannot be verified are what was last written
 * to them, so the parity of every vertical stripe may be recomputed from
 * the data on disk.  Otherwise only verified data is used.
 *
 * Return 0 if the stripe is consistent again and its record can go, 1 if it
 * must stay recorded, a negative error on a fatal error.  @start and @len
 * receive the full stripe geometry (@len is 0 if there is no such stripe
 * anymore).
 */
static int wib_recover_one(struct btrfs_fs_info *fs_info, struct scrub_ctx *sctx,
			   u64 logical, bool trusted,
			   bool log_replay_pending, u64 *start, u64 *len,
			   struct wib_recovery_stats *st)
{
	struct btrfs_wib *wib = fs_info->wib;
	int ret;

	ret = btrfs_raid56_full_stripe_range(fs_info, logical, start, len);
	if (ret == -ENOENT) {
		/* Chunk gone or not RAID56 anymore, nothing to do. */
		*len = 0;
		st->skipped++;
		return 0;
	}
	if (ret < 0)
		return ret;

	ret = btrfs_scrub_raid56_full_stripe(fs_info, sctx, *start, trusted);
	if (ret == -ENOENT) {
		st->skipped++;
		return 0;
	}
	if (ret == -EIO) {
		btrfs_err(fs_info,
	"raid56 write-intent log: full stripe at %llu has unrepairable sectors, keeping it recorded",
			  *start);
		st->failed++;
		atomic64_inc(&wib->stat_recovery_errors);
		return 1;
	}
	if (ret < 0) {
		btrfs_err(fs_info,
	"raid56 write-intent log: failed to recover full stripe at %llu: %d, keeping it recorded",
			  *start, ret);
		st->failed++;
		atomic64_inc(&wib->stat_recovery_errors);
		/* Only a resource shortage is worth failing the mount for. */
		if (ret == -ENOMEM)
			return ret;
		return 1;
	}
	st->done++;
	atomic64_inc(&wib->stat_recovered_stripes);
	/*
	 * A device is missing: its sectors of this stripe could be stale
	 * and were not repaired.  Keep the stripe recorded so that it is
	 * scrubbed again at the first mount with the device back (or
	 * replaced).
	 */
	if (ret == 1) {
		st->kept++;
		return 1;
	}
	/*
	 * An unreadable sector that holds no extent (as far as the extent
	 * tree knows) prevents recomputing the parity of its vertical
	 * stripe.  Nothing referenced depends on it, unless an extent is
	 * still hidden in the tree log: then look again after the replay.
	 */
	if (ret == 2) {
		if (log_replay_pending) {
			st->kept++;
			return 1;
		}
		btrfs_warn(fs_info,
	"raid56 write-intent log: full stripe at %llu has an unreadable sector holding no extent, its parity is left alone",
			   *start);
		return 0;
	}
	/* Verified what could be, the rest waits for the log replay. */
	if (!trusted) {
		st->kept++;
		return 1;
	}
	return 0;
}

/*
 * Recover every full stripe recorded in the log.  Must run before anything
 * is written to the filesystem (and after the block groups and the
 * extent/csum trees are available).
 *
 * @log_replay_pending: a tree log is about to be replayed, so extents only
 * it references are not visible yet.  Error records are then only verified
 * here and completed by btrfs_wib_recover_after_replay().
 */
int btrfs_wib_recover(struct btrfs_fs_info *fs_info, bool log_replay_pending)
{
	struct btrfs_wib *wib = fs_info->wib;
	struct wib_recovery_stats st = { 0 };
	struct scrub_ctx *sctx;
	u64 last_start = 0;
	u64 last_len = 0;
	int ret;

	if (!wib || !wib->nr_pending)
		return 0;

	/* One scrub context and workqueue for the whole pass, not one each. */
	sctx = btrfs_scrub_raid56_recovery_begin(fs_info);
	if (IS_ERR(sctx))
		return PTR_ERR(sctx);

	for (unsigned int i = 0; i < wib->nr_pending; i++) {
		const struct btrfs_wib_entry *e = &wib->pending[i];
		const u64 bits = e->bitmap | e->sticky;

		for (unsigned int bit = 0; bit < 64; bit++) {
			const u64 logical = e->bytenr + ((u64)bit << BTRFS_WIB_BLOCK_SHIFT);
			bool trusted;
			u64 start;
			u64 len;

			if (!(bits & (1ULL << bit)))
				continue;
			/* Already handled as part of the previous full stripe. */
			if (last_len && logical >= last_start &&
			    logical < last_start + last_len)
				continue;

			/*
			 * A large log can take a long time to replay.  Stay
			 * killable: the on-disk log is only rewritten after
			 * the whole pass, so aborting here leaves a superset
			 * and the next mount redoes the work.
			 */
			if (fatal_signal_pending(current) ||
			    btrfs_fs_closing(fs_info)) {
				btrfs_warn(fs_info,
	"raid56 write-intent log: recovery interrupted, it will be redone at the next mount");
				ret = -EINTR;
				goto out;
			}

			ret = btrfs_raid56_full_stripe_range(fs_info, logical, &start, &len);
			if (ret == -ENOENT) {
				st.skipped++;
				continue;
			}
			if (ret < 0)
				goto out;
			last_start = start;
			last_len = len;

			/*
			 * An error record means a write to this stripe
			 * completed with a device error, so a sector of it may
			 * be stale while the parity holds what was
			 * acknowledged.  Only verified sectors may be trusted:
			 * recomputing the parity from a sector the scrub
			 * cannot check would overwrite the copy that still has
			 * the acknowledged content.  A sector without a
			 * checksum is exactly such a sector -- see
			 * scrub_verify_one_sector(), which has "no other
			 * choice but to trust it" -- so on a nodatacow file
			 * this destroys data that was still recoverable.
			 *
			 * This is only about error records.  An in-flight
			 * record is a crash in the middle of an RMW, where no
			 * device reported anything and the data on disk is
			 * what the filesystem should present; recomputing the
			 * parity from it is right.  The log keeps the two in
			 * separate fields (bitmap and sticky) precisely so
			 * they can be told apart.
			 */
			trusted = !wib_pending_has_error(wib, start, len);
			ret = wib_recover_one(fs_info, sctx, start, trusted, log_replay_pending,
					      &start, &len, &st);
			if (ret < 0)
				goto out;
			if (ret == 1)
				btrfs_wib_add_sticky(fs_info, start, len);
		}
	}

	btrfs_info(fs_info,
	"raid56 write-intent log: recovery done, %u full stripes scrubbed, %u skipped, %u unrepairable, %u kept recorded",
		   st.done, st.skipped, st.failed, st.kept);

	kvfree(wib->pending);
	wib->pending = NULL;
	wib->nr_pending = 0;
	wib->max_pending = 0;

	/*
	 * Make the regenerated parity durable and overwrite both on-disk
	 * slots with the new set, so that a later crash doesn't redo the
	 * work.  This is done whether or not the log stays enabled: a stale
	 * valid block would otherwise be replayed at every mount.
	 */
	ret = wib_persist_all_slots(wib, BTRFS_WIB_NR_SLOTS);
out:
	btrfs_scrub_raid56_recovery_end(fs_info, sctx);
	return ret;
}

/*
 * The tree log has been replayed: every extent is visible in the commit
 * roots now.  Complete the recovery of the stripes kept recorded by
 * btrfs_wib_recover() because their unverifiable sectors could not be
 * trusted; they can be verified now.
 */
int btrfs_wib_recover_after_replay(struct btrfs_fs_info *fs_info)
{
	struct btrfs_wib *wib = fs_info->wib;
	struct wib_recovery_stats st = { 0 };
	struct btrfs_wib_entry *snap;
	struct scrub_ctx *sctx;
	unsigned int nr = 0;
	u64 last_start = 0;
	u64 last_len = 0;
	int ret = 0;

	if (!wib)
		return 0;

	snap = kvcalloc(BTRFS_WIB_MAX_ENTRIES, sizeof(*snap), GFP_KERNEL);
	if (!snap)
		return -ENOMEM;
	spin_lock(&wib->lock);
	for (int i = 0; i < BTRFS_WIB_MAX_ENTRIES; i++) {
		if (wib->entries[i].sticky)
			snap[nr++] = wib->entries[i];
	}
	spin_unlock(&wib->lock);
	if (nr == 0)
		goto out;

	sctx = btrfs_scrub_raid56_recovery_begin(fs_info);
	if (IS_ERR(sctx)) {
		ret = PTR_ERR(sctx);
		goto out;
	}

	for (unsigned int i = 0; i < nr; i++) {
		const struct btrfs_wib_entry *e = &snap[i];

		for (unsigned int bit = 0; bit < 64; bit++) {
			const u64 logical = e->bytenr + ((u64)bit << BTRFS_WIB_BLOCK_SHIFT);
			u64 start;
			u64 len;

			if (!(e->sticky & (1ULL << bit)))
				continue;
			if (last_len && logical >= last_start &&
			    logical < last_start + last_len)
				continue;
			if (fatal_signal_pending(current) ||
			    btrfs_fs_closing(fs_info)) {
				btrfs_warn(fs_info,
	"raid56 write-intent log: recovery interrupted, it will be redone at the next mount");
				ret = -EINTR;
				goto out_end;
			}

			ret = wib_recover_one(fs_info, sctx, logical, true, false, &start, &len, &st);
			if (ret < 0)
				goto out_end;
			if (!len) {
				/* No RAID56 stripe there anymore. */
				btrfs_wib_clear_sticky(fs_info, logical, BTRFS_WIB_BLOCK_SIZE);
				continue;
			}
			last_start = start;
			last_len = len;
			if (ret == 0)
				btrfs_wib_clear_sticky(fs_info, start, len);
		}
	}

	btrfs_info(fs_info,
	"raid56 write-intent log: recovery after log replay done, %u full stripes scrubbed, %u skipped, %u unrepairable, %u kept recorded",
		   st.done, st.skipped, st.failed, st.kept);
	ret = wib_persist_all_slots(wib, 1);
out_end:
	btrfs_scrub_raid56_recovery_end(fs_info, sctx);
out:
	kvfree(snap);
	return ret;
}

/*
 * Everything that has to happen when the filesystem becomes writable:
 * recover the logged stripes, then enable the log if the feature flag is
 * set or if the filesystem uses RAID56 and the user didn't opt out.
 *
 * Also used, with @log_replay_pending and @rdonly, before a tree log is
 * replayed on a read-only mount (the replay writes to the devices); the
 * feature flag is not set in that case.
 */
int btrfs_wib_rw_mount(struct btrfs_fs_info *fs_info, bool log_replay_pending,
		       bool rdonly)
{
	struct btrfs_wib *wib = fs_info->wib;
	int ret;

	if (!wib)
		return 0;
	/* Read-only media: nothing can be written, the log replay fails too. */
	if (rdonly && fs_info->fs_devices->rw_devices == 0)
		return 0;

	if (btrfs_fs_compat_ro(fs_info, RAID56_WRITE_INTENT) && btrfs_is_zoned(fs_info)) {
		btrfs_err(fs_info,
			  "raid56 write-intent log is not supported on zoned filesystems");
		return -EOPNOTSUPP;
	}

	/* Recovery must precede any other write. */
	ret = btrfs_wib_recover(fs_info, log_replay_pending);
	if (ret)
		return ret;

	if (btrfs_fs_compat_ro(fs_info, RAID56_WRITE_INTENT) ||
	    (rdonly && btrfs_fs_incompat(fs_info, RAID56) && !btrfs_is_zoned(fs_info))) {
		ret = btrfs_wib_enable(fs_info);
		if (ret)
			return ret;
	}

	if (!rdonly &&
	    !btrfs_fs_compat_ro(fs_info, RAID56_WRITE_INTENT) &&
	    btrfs_fs_incompat(fs_info, RAID56) &&
	    !btrfs_test_opt(fs_info, NORAID56_WRITE_INTENT) &&
	    !btrfs_is_zoned(fs_info)) {
		btrfs_info(fs_info,
	"enabling raid56 write-intent log, older kernels will only mount this filesystem read-only");
		ret = btrfs_wib_enable(fs_info);
		if (ret)
			return ret;
		btrfs_set_fs_compat_ro(fs_info, RAID56_WRITE_INTENT);
	}
	return 0;
}
