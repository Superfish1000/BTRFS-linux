// SPDX-License-Identifier: GPL-2.0
/*
 * Self tests for the RAID56 write-intent log (in-memory tracking, on-disk
 * block encoding, torn block detection, recovery list merging and the
 * enable/disable ordering).
 *
 * The dummy fs_info has no devices, so commits build the block but write it
 * nowhere; the block content is verified through wib->last.
 */

#include <linux/types.h>
#include "btrfs-tests.h"
#include "../ctree.h"
#include "../fs.h"
#include "../volumes.h"
#include "../accessors.h"
#include "../raid56-wib.h"

static const u8 test_uuid[BTRFS_FSID_SIZE] = {
	0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
	0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00,
};

static int check_block_entry(const void *block, u32 index, u64 bytenr, u64 bitmap,
			     u64 error)
{
	const struct btrfs_wib_disk_header *hdr = block;
	const struct btrfs_wib_disk_entry *de = block + sizeof(*hdr);

	if (le32_to_cpu(hdr->nr_entries) <= index) {
		test_err("block has %u entries, expected entry %u",
			 le32_to_cpu(hdr->nr_entries), index);
		return -EINVAL;
	}
	if (le64_to_cpu(de[index].bytenr) != bytenr ||
	    le64_to_cpu(de[index].bitmap) != bitmap ||
	    le64_to_cpu(de[index].error) != error) {
		test_err("entry %u is (%llu, 0x%llx, 0x%llx), expected (%llu, 0x%llx, 0x%llx)",
			 index, le64_to_cpu(de[index].bytenr),
			 le64_to_cpu(de[index].bitmap), le64_to_cpu(de[index].error),
			 bytenr, bitmap, error);
		return -EINVAL;
	}
	return 0;
}

static u32 block_nr_entries(const void *block)
{
	return le32_to_cpu(((const struct btrfs_wib_disk_header *)block)->nr_entries);
}

static int test_range_mask(void)
{
	const u64 base = 3 * BTRFS_WIB_ENTRY_SIZE;

	/* Single 64K block at the start of the entry. */
	if (btrfs_wib_range_mask(base, base, BTRFS_WIB_BLOCK_SIZE) != 0x1) {
		test_err("range mask for first block wrong");
		return -EINVAL;
	}
	/* Last block of the entry. */
	if (btrfs_wib_range_mask(base, base + 63 * BTRFS_WIB_BLOCK_SIZE,
				 BTRFS_WIB_BLOCK_SIZE) != (1ULL << 63)) {
		test_err("range mask for last block wrong");
		return -EINVAL;
	}
	/* A 3 data stripe RAID5 full stripe (192K) straddling two entries. */
	if (btrfs_wib_range_mask(base, base + 62 * BTRFS_WIB_BLOCK_SIZE,
				 3 * BTRFS_WIB_BLOCK_SIZE) != (0x3ULL << 62)) {
		test_err("range mask for straddling stripe, first entry wrong");
		return -EINVAL;
	}
	if (btrfs_wib_range_mask(base + BTRFS_WIB_ENTRY_SIZE,
				 base + 62 * BTRFS_WIB_BLOCK_SIZE,
				 3 * BTRFS_WIB_BLOCK_SIZE) != 0x1) {
		test_err("range mask for straddling stripe, second entry wrong");
		return -EINVAL;
	}
	/* Disjoint range. */
	if (btrfs_wib_range_mask(base, base + BTRFS_WIB_ENTRY_SIZE, SZ_64K) != 0) {
		test_err("range mask for disjoint range not zero");
		return -EINVAL;
	}
	/* Whole entry. */
	if (btrfs_wib_range_mask(base, base, BTRFS_WIB_ENTRY_SIZE) != ~0ULL) {
		test_err("range mask for whole entry wrong");
		return -EINVAL;
	}
	return 0;
}

static int test_mark_commit_done(struct btrfs_fs_info *fs_info)
{
	struct btrfs_wib *wib = fs_info->wib;
	const struct btrfs_wib_disk_header *hdr = wib->last;
	const u64 stripe_a = 5 * BTRFS_WIB_ENTRY_SIZE + 4 * BTRFS_WIB_BLOCK_SIZE;
	const u64 stripe_b = 9 * BTRFS_WIB_ENTRY_SIZE + 62 * BTRFS_WIB_BLOCK_SIZE;
	const u64 stripe_c = 12 * BTRFS_WIB_ENTRY_SIZE;
	void *saved;
	int ret;

	saved = kmalloc(BTRFS_WIB_SLOT_SIZE, GFP_KERNEL);
	if (!saved)
		return -ENOMEM;

	/* Not enabled: marks are tracked in memory only, no commit happens. */
	ret = btrfs_wib_mark(fs_info, stripe_a, 2 * BTRFS_WIB_BLOCK_SIZE);
	if (ret) {
		test_err("mark failed: %d", ret);
		goto out;
	}
	if (wib->seq != 0 || le64_to_cpu(hdr->magic) == BTRFS_WIB_MAGIC) {
		test_err("commit happened while the log was disabled");
		ret = -EINVAL;
		goto out;
	}

	/* Enabling persists what is in flight. */
	ret = btrfs_wib_enable(fs_info);
	if (ret) {
		test_err("enable failed: %d", ret);
		goto out;
	}
	if (!btrfs_wib_block_valid(fs_info, wib->last)) {
		test_err("committed block is not valid");
		ret = -EINVAL;
		goto out;
	}
	if (le64_to_cpu(hdr->seq) != 1 || wib->seq != 1) {
		test_err("first commit has seq %llu/%llu, expected 1",
			 le64_to_cpu(hdr->seq), wib->seq);
		ret = -EINVAL;
		goto out;
	}
	ret = check_block_entry(wib->last, 0, 5 * BTRFS_WIB_ENTRY_SIZE, 0x3ULL << 4, 0);
	if (ret)
		goto out;

	/* A stripe straddling two entries. */
	ret = btrfs_wib_mark(fs_info, stripe_b, 3 * BTRFS_WIB_BLOCK_SIZE);
	if (ret) {
		test_err("second mark failed: %d", ret);
		goto out;
	}
	if (block_nr_entries(wib->last) != 3 || wib->seq != 2) {
		test_err("after second mark: %u entries, seq %llu",
			 block_nr_entries(wib->last), wib->seq);
		ret = -EINVAL;
		goto out;
	}
	ret = check_block_entry(wib->last, 1, 9 * BTRFS_WIB_ENTRY_SIZE, 0x3ULL << 62, 0);
	if (ret)
		goto out;
	ret = check_block_entry(wib->last, 2, 10 * BTRFS_WIB_ENTRY_SIZE, 0x1, 0);
	if (ret)
		goto out;

	/* A mark that is already covered doesn't need a new commit. */
	ret = btrfs_wib_mark(fs_info, stripe_a, 2 * BTRFS_WIB_BLOCK_SIZE);
	if (ret) {
		test_err("re-mark failed: %d", ret);
		goto out;
	}
	if (le64_to_cpu(hdr->seq) != 2) {
		test_err("re-mark rewrote the block (seq %llu)", le64_to_cpu(hdr->seq));
		ret = -EINVAL;
		goto out;
	}

	/* An unaligned mark is widened to whole blocks. */
	ret = btrfs_wib_mark(fs_info, stripe_a + SZ_4K, SZ_4K);
	if (ret) {
		test_err("unaligned mark failed: %d", ret);
		goto out;
	}
	if (le64_to_cpu(hdr->seq) != 2) {
		test_err("unaligned mark inside a marked block rewrote the block");
		ret = -EINVAL;
		goto out;
	}

	/* Done clears in memory only; the committed block is untouched. */
	memcpy(saved, wib->last, BTRFS_WIB_SLOT_SIZE);
	btrfs_wib_done(fs_info, stripe_a, 2 * BTRFS_WIB_BLOCK_SIZE, false);
	if (block_nr_entries(wib->last) != 3) {
		test_err("done modified the committed block");
		ret = -EINVAL;
		goto out;
	}
	/*
	 * A mark-time commit only adds: the finished stripe stays listed
	 * (no flush happened that would allow dropping it).
	 */
	ret = btrfs_wib_mark(fs_info, stripe_c, BTRFS_WIB_BLOCK_SIZE);
	if (ret) {
		test_err("third mark failed: %d", ret);
		goto out;
	}
	if (block_nr_entries(wib->last) != 4 || btrfs_wib_block_drops(saved, wib->last)) {
		test_err("mark-time commit dropped a finished stripe (%u entries)",
			 block_nr_entries(wib->last));
		ret = -EINVAL;
		goto out;
	}
	ret = check_block_entry(wib->last, 3, 5 * BTRFS_WIB_ENTRY_SIZE, 0x3ULL << 4, 0);
	if (ret)
		goto out;
	btrfs_wib_done(fs_info, stripe_c, BTRFS_WIB_BLOCK_SIZE, false);

	/* The transaction commit, after a confirmed flush, drops it. */
	btrfs_wib_commit_prepare(fs_info);
	ret = btrfs_wib_commit(fs_info, true);
	if (ret) {
		test_err("commit failed: %d", ret);
		goto out;
	}
	if (block_nr_entries(wib->last) != 2) {
		test_err("commit after done kept %u entries", block_nr_entries(wib->last));
		ret = -EINVAL;
		goto out;
	}
	if (!btrfs_wib_block_drops(saved, wib->last)) {
		test_err("drop of a finished stripe not detected");
		ret = -EINVAL;
		goto out;
	}
	if (btrfs_wib_block_drops(wib->last, saved)) {
		test_err("false drop detected");
		ret = -EINVAL;
		goto out;
	}

	/* Nothing changed: commit is a no-op. */
	btrfs_wib_commit_prepare(fs_info);
	ret = btrfs_wib_commit(fs_info, true);
	if (ret) {
		test_err("no-op commit failed: %d", ret);
		goto out;
	}
	if (atomic64_read(&wib->stat_commits) != 4) {
		test_err("no-op commit did IO (%llu commits)",
			 (unsigned long long)atomic64_read(&wib->stat_commits));
		ret = -EINVAL;
		goto out;
	}

	/* But not if the last block is not known to have reached every device. */
	wib->last_ok = false;
	btrfs_wib_commit_prepare(fs_info);
	ret = btrfs_wib_commit(fs_info, true);
	if (ret)
		goto out;
	if (atomic64_read(&wib->stat_commits) != 5 || !wib->last_ok) {
		test_err("commit after a failed one did no IO");
		ret = -EINVAL;
		goto out;
	}

	/*
	 * A device did not confirm the flush: the finished stripe must not
	 * be dropped, it becomes an error record.
	 */
	btrfs_wib_done(fs_info, stripe_b, 3 * BTRFS_WIB_BLOCK_SIZE, false);
	btrfs_wib_commit_prepare(fs_info);
	ret = btrfs_wib_commit(fs_info, false);
	if (ret)
		goto out;
	if (block_nr_entries(wib->last) != 2) {
		test_err("commit without a confirmed flush dropped a stripe (%u entries)",
			 block_nr_entries(wib->last));
		ret = -EINVAL;
		goto out;
	}
	/* Still listed as in flight (union with the last block) and as an error record. */
	ret = check_block_entry(wib->last, 0, 9 * BTRFS_WIB_ENTRY_SIZE, 0x3ULL << 62,
				0x3ULL << 62);
	if (ret)
		goto out;
	ret = check_block_entry(wib->last, 1, 10 * BTRFS_WIB_ENTRY_SIZE, 0x1, 0x1);
	if (ret)
		goto out;
	btrfs_wib_clear_sticky(fs_info, stripe_b, 3 * BTRFS_WIB_BLOCK_SIZE);
	btrfs_wib_commit_prepare(fs_info);
	ret = btrfs_wib_commit(fs_info, true);
	if (ret)
		goto out;
	if (block_nr_entries(wib->last) != 0) {
		test_err("log not empty after all stripes finished");
		ret = -EINVAL;
		goto out;
	}

	/*
	 * A stripe recorded and finished between the transaction commit's
	 * snapshot and its (flushed) log write may have written during the
	 * flush: it must stay listed.
	 */
	btrfs_wib_commit_prepare(fs_info);
	ret = btrfs_wib_mark(fs_info, stripe_c, BTRFS_WIB_BLOCK_SIZE);
	if (ret)
		goto out;
	btrfs_wib_done(fs_info, stripe_c, BTRFS_WIB_BLOCK_SIZE, false);
	ret = btrfs_wib_commit(fs_info, true);
	if (ret)
		goto out;
	if (block_nr_entries(wib->last) != 1) {
		test_err("stripe recorded after the snapshot dropped by the flushed commit");
		ret = -EINVAL;
		goto out;
	}
	ret = check_block_entry(wib->last, 0, stripe_c, 0x1, 0);
	if (ret)
		goto out;
	btrfs_wib_commit_prepare(fs_info);
	ret = btrfs_wib_commit(fs_info, true);
	if (ret)
		goto out;
	if (block_nr_entries(wib->last) != 0) {
		test_err("finished stripe not dropped by the next flushed commit");
		ret = -EINVAL;
		goto out;
	}
	ret = 0;
out:
	kfree(saved);
	return ret;
}

/*
 * Re-stamp the checksum after doctoring a header field, so that a rejection
 * proves the field check fired rather than the checksum.
 */
static void restamp(struct btrfs_fs_info *fs_info, void *block)
{
	struct btrfs_wib_disk_header *hdr = block;

	btrfs_csum(fs_info->csum_type, block + BTRFS_CSUM_SIZE,
		   BTRFS_WIB_SLOT_SIZE - BTRFS_CSUM_SIZE, hdr->csum);
}

static int test_torn_block(struct btrfs_fs_info *fs_info)
{
	struct btrfs_wib *wib = fs_info->wib;
	struct btrfs_wib_disk_header *hdr;
	void *block;
	int ret = -EINVAL;

	block = kmalloc(BTRFS_WIB_SLOT_SIZE, GFP_KERNEL);
	if (!block)
		return -ENOMEM;
	hdr = block;

	btrfs_wib_build_block(wib, block, 42, NULL);
	if (!btrfs_wib_block_valid(fs_info, block)) {
		test_err("freshly built block not valid");
		goto out;
	}
	/* Torn write: a byte in the entry area changed. */
	((u8 *)block)[BTRFS_WIB_SLOT_SIZE - 1] ^= 0x5a;
	if (btrfs_wib_block_valid(fs_info, block)) {
		test_err("corrupted block accepted");
		goto out;
	}
	((u8 *)block)[BTRFS_WIB_SLOT_SIZE - 1] ^= 0x5a;

	/* Block of another filesystem. */
	hdr->fsid[0] ^= 1;
	if (btrfs_wib_block_valid(fs_info, block)) {
		test_err("block with foreign fsid accepted");
		goto out;
	}
	hdr->fsid[0] ^= 1;

	/* Bad magic. */
	hdr->magic = 0;
	if (btrfs_wib_block_valid(fs_info, block)) {
		test_err("block with bad magic accepted");
		goto out;
	}

	/* All zero (never written) block. */
	memset(block, 0, BTRFS_WIB_SLOT_SIZE);
	if (btrfs_wib_block_valid(fs_info, block)) {
		test_err("zeroed block accepted");
		goto out;
	}

	/*
	 * A block written by a kernel that understands more of the format than
	 * this one.  Each field is set and the checksum re-stamped, so that
	 * what rejects the block is the field check and not merely a checksum
	 * that no longer matches -- otherwise these would pass whether or not
	 * the checks exist.
	 */
	btrfs_wib_build_block(wib, block, 43, NULL);
	hdr->flags = cpu_to_le64(1);
	restamp(fs_info, block);
	if (btrfs_wib_block_valid(fs_info, block)) {
		test_err("block with an unknown flag accepted");
		goto out;
	}

	btrfs_wib_build_block(wib, block, 44, NULL);
	hdr->reserved[3] = cpu_to_le64(0xdeadbeef);
	restamp(fs_info, block);
	if (btrfs_wib_block_valid(fs_info, block)) {
		test_err("block using a reserved field accepted");
		goto out;
	}

	btrfs_wib_build_block(wib, block, 45, NULL);
	hdr->block_shift = cpu_to_le32(BTRFS_WIB_BLOCK_SHIFT + 1);
	restamp(fs_info, block);
	if (btrfs_wib_block_valid(fs_info, block)) {
		test_err("block with a different granularity accepted");
		goto out;
	}

	/* An entry count that would index past the end of the slot. */
	btrfs_wib_build_block(wib, block, 46, NULL);
	hdr->nr_entries = cpu_to_le32(BTRFS_WIB_MAX_ENTRIES + 1);
	restamp(fs_info, block);
	if (btrfs_wib_block_valid(fs_info, block)) {
		test_err("block with an out of range entry count accepted");
		goto out;
	}

	/* And the same block is still good once the field is put back. */
	btrfs_wib_build_block(wib, block, 47, NULL);
	if (!btrfs_wib_block_valid(fs_info, block)) {
		test_err("rebuilt block not valid");
		goto out;
	}
	ret = 0;
out:
	kfree(block);
	return ret;
}

static int test_pending_merge(struct btrfs_fs_info *fs_info)
{
	struct btrfs_wib *wib = fs_info->wib;
	int ret;

	/* Simulate the union of the newest slots of several devices. */
	ret = btrfs_wib_add_pending(wib, 8 * BTRFS_WIB_ENTRY_SIZE, 0x00f0, 0);
	ret |= btrfs_wib_add_pending(wib, 2 * BTRFS_WIB_ENTRY_SIZE, 0x0001, 0);
	ret |= btrfs_wib_add_pending(wib, 8 * BTRFS_WIB_ENTRY_SIZE, 0x0f00, 0x0010);
	ret |= btrfs_wib_add_pending(wib, 2 * BTRFS_WIB_ENTRY_SIZE, 0x0000, 0);
	ret |= btrfs_wib_add_pending(wib, 5 * BTRFS_WIB_ENTRY_SIZE, 0x0000, 0x8000);
	if (ret) {
		test_err("add_pending failed");
		return -EINVAL;
	}
	btrfs_wib_finalize_pending(wib);
	if (wib->nr_pending != 3) {
		test_err("pending merge produced %u entries, expected 3", wib->nr_pending);
		return -EINVAL;
	}
	if (wib->pending[0].bytenr != 2 * BTRFS_WIB_ENTRY_SIZE ||
	    wib->pending[0].bitmap != 0x0001 || wib->pending[0].sticky != 0 ||
	    wib->pending[1].bytenr != 5 * BTRFS_WIB_ENTRY_SIZE ||
	    wib->pending[1].bitmap != 0 || wib->pending[1].sticky != 0x8000 ||
	    wib->pending[2].bytenr != 8 * BTRFS_WIB_ENTRY_SIZE ||
	    wib->pending[2].bitmap != 0x0ff0 || wib->pending[2].sticky != 0x0010) {
		test_err("pending merge produced wrong entries");
		return -EINVAL;
	}
	kvfree(wib->pending);
	wib->pending = NULL;
	wib->nr_pending = 0;
	wib->max_pending = 0;
	return 0;
}

static int test_log_full(struct btrfs_fs_info *fs_info)
{
	struct btrfs_wib *wib = fs_info->wib;
	const u64 straddling = 50 * BTRFS_WIB_ENTRY_SIZE + 63 * BTRFS_WIB_BLOCK_SIZE;
	int ret;

	/* Fill every entry with a distinct region. */
	for (u64 i = 0; i < BTRFS_WIB_MAX_ENTRIES; i++) {
		ret = btrfs_wib_mark(fs_info, (i + 100) * BTRFS_WIB_ENTRY_SIZE,
				     BTRFS_WIB_BLOCK_SIZE);
		if (ret) {
			test_err("mark %llu failed: %d", i, ret);
			return ret;
		}
	}

	/* A region already present still fits. */
	spin_lock(&wib->lock);
	ret = btrfs_wib_try_mark(wib, 100 * BTRFS_WIB_ENTRY_SIZE + SZ_1M, BTRFS_WIB_BLOCK_SIZE);
	spin_unlock(&wib->lock);
	if (ret) {
		test_err("mark of a present region failed on a full log: %d", ret);
		return -EINVAL;
	}

	/* A new region must be refused, not silently dropped. */
	spin_lock(&wib->lock);
	ret = btrfs_wib_try_mark(wib, 0, BTRFS_WIB_BLOCK_SIZE);
	spin_unlock(&wib->lock);
	if (ret != -ENOSPC || btrfs_wib_can_mark(wib, 0, BTRFS_WIB_BLOCK_SIZE)) {
		test_err("full log accepted a new region: %d", ret);
		return -EINVAL;
	}

	/* Finishing a stripe frees its entry for reuse. */
	btrfs_wib_done(fs_info, 150 * BTRFS_WIB_ENTRY_SIZE, BTRFS_WIB_BLOCK_SIZE, false);
	if (!btrfs_wib_can_mark(wib, 0, BTRFS_WIB_BLOCK_SIZE)) {
		test_err("freed entry not seen as available");
		return -EINVAL;
	}

	/*
	 * A stripe straddling two entries needs two free ones: with one it
	 * must be refused as a whole (and nothing left behind), so that a
	 * waiter is not woken to fail again.
	 */
	if (btrfs_wib_can_mark(wib, straddling, 2 * BTRFS_WIB_BLOCK_SIZE)) {
		test_err("straddling stripe accepted with a single free entry");
		return -EINVAL;
	}
	spin_lock(&wib->lock);
	ret = btrfs_wib_try_mark(wib, straddling, 2 * BTRFS_WIB_BLOCK_SIZE);
	spin_unlock(&wib->lock);
	if (ret != -ENOSPC) {
		test_err("straddling stripe marked with a single free entry: %d", ret);
		return -EINVAL;
	}
	ret = btrfs_wib_mark(fs_info, 0, BTRFS_WIB_BLOCK_SIZE);
	if (ret) {
		test_err("mark after freeing an entry failed (refused straddling stripe left bits behind?): %d",
			 ret);
		return ret;
	}
	btrfs_wib_done(fs_info, 0, BTRFS_WIB_BLOCK_SIZE, false);
	btrfs_wib_done(fs_info, 151 * BTRFS_WIB_ENTRY_SIZE, BTRFS_WIB_BLOCK_SIZE, false);
	if (!btrfs_wib_can_mark(wib, straddling, 2 * BTRFS_WIB_BLOCK_SIZE)) {
		test_err("straddling stripe refused with two free entries");
		return -EINVAL;
	}
	ret = btrfs_wib_mark(fs_info, straddling, 2 * BTRFS_WIB_BLOCK_SIZE);
	if (ret) {
		test_err("straddling stripe mark failed: %d", ret);
		return ret;
	}

	/*
	 * The on-disk block lists every region ever marked since the last
	 * drop; when the union does not fit anymore a mark-time commit has
	 * to flush and drop the finished ones itself.
	 */
	btrfs_wib_done(fs_info, straddling, 2 * BTRFS_WIB_BLOCK_SIZE, false);
	btrfs_wib_done(fs_info, 100 * BTRFS_WIB_ENTRY_SIZE + SZ_1M, BTRFS_WIB_BLOCK_SIZE, false);
	for (u64 i = 0; i < BTRFS_WIB_MAX_ENTRIES; i++)
		btrfs_wib_done(fs_info, (i + 100) * BTRFS_WIB_ENTRY_SIZE,
			       BTRFS_WIB_BLOCK_SIZE, false);
	ret = btrfs_wib_mark(fs_info, 0, BTRFS_WIB_BLOCK_SIZE);
	if (ret) {
		test_err("mark with a full on-disk block failed: %d", ret);
		return ret;
	}
	if (block_nr_entries(wib->last) != 1 ||
	    atomic64_read(&wib->stat_commit_flushes) == 0) {
		test_err("mark-time commit did not drop finished stripes when the block was full (%u entries)",
			 block_nr_entries(wib->last));
		return -EINVAL;
	}
	btrfs_wib_done(fs_info, 0, BTRFS_WIB_BLOCK_SIZE, false);
	btrfs_wib_commit_prepare(fs_info);
	ret = btrfs_wib_commit(fs_info, true);
	if (ret)
		return ret;
	if (block_nr_entries(wib->last) != 0) {
		test_err("log not empty after cleanup");
		return -EINVAL;
	}
	return 0;
}

static int test_sticky(struct btrfs_fs_info *fs_info)
{
	struct btrfs_wib *wib = fs_info->wib;
	const u64 stripe = 20 * BTRFS_WIB_ENTRY_SIZE;
	int ret;

	/* A stripe whose write failed stays in the on-disk log as an error record. */
	ret = btrfs_wib_mark(fs_info, stripe, 3 * BTRFS_WIB_BLOCK_SIZE);
	if (ret)
		return ret;
	btrfs_wib_done(fs_info, stripe, 3 * BTRFS_WIB_BLOCK_SIZE, true);
	btrfs_wib_commit_prepare(fs_info);
	ret = btrfs_wib_commit(fs_info, true);
	if (ret)
		return ret;
	if (block_nr_entries(wib->last) != 1) {
		test_err("failed stripe dropped from the log");
		return -EINVAL;
	}
	ret = check_block_entry(wib->last, 0, stripe, 0, 0x7);
	if (ret)
		return ret;

	/* A new write to the same stripe is listed in both kinds. */
	ret = btrfs_wib_mark(fs_info, stripe, 3 * BTRFS_WIB_BLOCK_SIZE);
	if (ret)
		return ret;
	ret = check_block_entry(wib->last, 0, stripe, 0x7, 0x7);
	if (ret)
		return ret;
	btrfs_wib_done(fs_info, stripe, 3 * BTRFS_WIB_BLOCK_SIZE, false);
	btrfs_wib_commit_prepare(fs_info);
	ret = btrfs_wib_commit(fs_info, true);
	if (ret)
		return ret;
	ret = check_block_entry(wib->last, 0, stripe, 0, 0x7);
	if (ret)
		return ret;

	/* Recovery clears the error record once the stripe is verified. */
	btrfs_wib_clear_sticky(fs_info, stripe, 3 * BTRFS_WIB_BLOCK_SIZE);
	btrfs_wib_commit_prepare(fs_info);
	ret = btrfs_wib_commit(fs_info, true);
	if (ret)
		return ret;
	if (block_nr_entries(wib->last) != 0) {
		test_err("cleared error record still in the log");
		return -EINVAL;
	}

	/* Sticky entries are evicted when the log is full. */
	btrfs_wib_add_sticky(fs_info, stripe, 3 * BTRFS_WIB_BLOCK_SIZE);
	for (u64 i = 0; i < BTRFS_WIB_MAX_ENTRIES; i++) {
		ret = btrfs_wib_mark(fs_info, (i + 300) * BTRFS_WIB_ENTRY_SIZE,
				     BTRFS_WIB_BLOCK_SIZE);
		if (ret) {
			test_err("mark %llu with a sticky entry present failed: %d", i, ret);
			return ret;
		}
	}
	if (atomic64_read(&wib->stat_sticky_evicted) != 1) {
		test_err("sticky entry not evicted");
		return -EINVAL;
	}
	for (u64 i = 0; i < BTRFS_WIB_MAX_ENTRIES; i++)
		btrfs_wib_done(fs_info, (i + 300) * BTRFS_WIB_ENTRY_SIZE,
			       BTRFS_WIB_BLOCK_SIZE, false);
	btrfs_wib_commit_prepare(fs_info);
	ret = btrfs_wib_commit(fs_info, true);
	if (ret)
		return ret;
	if (block_nr_entries(wib->last) != 0) {
		test_err("log not empty after sticky test");
		return -EINVAL;
	}
	return 0;
}

/*
 * Disabling must keep the log maintained until a superblock without the
 * feature flag is durable, i.e. until the commit after the one that writes
 * such a superblock.
 */
static int test_disable_ordering(struct btrfs_fs_info *fs_info)
{
	struct btrfs_wib *wib = fs_info->wib;
	const u64 stripe = 30 * BTRFS_WIB_ENTRY_SIZE;
	int ret;

	btrfs_set_super_compat_ro_flags(fs_info->super_for_commit,
					BTRFS_FEATURE_COMPAT_RO_RAID56_WRITE_INTENT);
	btrfs_wib_disable(fs_info);
	if (!wib->enabled) {
		test_err("disable took effect immediately");
		return -EINVAL;
	}

	/* This commit still writes a superblock with the flag: keep going. */
	btrfs_wib_commit_prepare(fs_info);
	ret = btrfs_wib_commit(fs_info, true);
	if (ret)
		return ret;
	ret = btrfs_wib_mark(fs_info, stripe, BTRFS_WIB_BLOCK_SIZE);
	if (ret)
		return ret;
	if (!wib->enabled || block_nr_entries(wib->last) != 1) {
		test_err("log not maintained while the flag is still on disk");
		return -EINVAL;
	}
	btrfs_wib_done(fs_info, stripe, BTRFS_WIB_BLOCK_SIZE, false);

	/* The flag is cleared for the next superblock: armed, still logging. */
	btrfs_set_super_compat_ro_flags(fs_info->super_for_commit, 0);
	btrfs_wib_commit_prepare(fs_info);
	ret = btrfs_wib_commit(fs_info, true);
	if (ret)
		return ret;
	if (!wib->enabled) {
		test_err("disabled before the superblock without the flag was written");
		return -EINVAL;
	}
	/* The following commit knows it is durable. */
	btrfs_wib_commit_prepare(fs_info);
	ret = btrfs_wib_commit(fs_info, true);
	if (ret)
		return ret;
	if (wib->enabled) {
		test_err("not disabled after the superblock without the flag was written");
		return -EINVAL;
	}

	/* Enable again for the remaining tests (and the enable request path). */
	btrfs_wib_request_enable(fs_info, true);
	if (!wib->enable_requested ||
	    !btrfs_fs_compat_ro(fs_info, RAID56_WRITE_INTENT)) {
		test_err("enable request did not set the feature flag");
		return -EINVAL;
	}
	btrfs_wib_commit_prepare(fs_info);
	ret = btrfs_wib_commit(fs_info, true);
	if (ret)
		return ret;
	if (!wib->enabled || wib->enable_requested) {
		test_err("enable request not honoured at commit");
		return -EINVAL;
	}
	return 0;
}

int btrfs_test_raid56_wib(u32 sectorsize, u32 nodesize)
{
	struct btrfs_fs_info *fs_info;
	int ret;

	test_msg("running raid56 write-intent log tests");

	fs_info = btrfs_alloc_dummy_fs_info(nodesize, sectorsize);
	if (!fs_info) {
		test_std_err(TEST_ALLOC_FS_INFO);
		return -ENOMEM;
	}
	fs_info->csum_type = BTRFS_CSUM_TYPE_CRC32;
	memcpy(fs_info->fs_devices->metadata_uuid, test_uuid, BTRFS_FSID_SIZE);
	mutex_init(&fs_info->fs_devices->device_list_mutex);
	fs_info->super_for_commit = kzalloc_obj(struct btrfs_super_block);
	if (!fs_info->super_for_commit) {
		ret = -ENOMEM;
		goto out;
	}

	ret = btrfs_wib_alloc(fs_info);
	if (ret) {
		test_err("failed to allocate the log: %d", ret);
		goto out;
	}

	ret = test_range_mask();
	if (ret)
		goto out;
	ret = test_mark_commit_done(fs_info);
	if (ret)
		goto out;
	ret = test_torn_block(fs_info);
	if (ret)
		goto out;
	ret = test_pending_merge(fs_info);
	if (ret)
		goto out;
	ret = test_log_full(fs_info);
	if (ret)
		goto out;
	ret = test_sticky(fs_info);
	if (ret)
		goto out;
	ret = test_disable_ordering(fs_info);
out:
	kfree(fs_info->super_for_commit);
	fs_info->super_for_commit = NULL;
	btrfs_free_dummy_fs_info(fs_info);
	return ret;
}
