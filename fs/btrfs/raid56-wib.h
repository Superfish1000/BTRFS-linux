/* SPDX-License-Identifier: GPL-2.0 */
/*
 * RAID56 write-intent log ("wib": write-intent bitmap).
 *
 * See raid56-wib.c for the design and the crash-consistency argument.
 */

#ifndef BTRFS_RAID56_WIB_H
#define BTRFS_RAID56_WIB_H

#include <linux/types.h>
#include <linux/sizes.h>
#include <linux/spinlock.h>
#include <linux/mutex.h>
#include <linux/wait.h>
#include <linux/atomic.h>
#include <uapi/linux/btrfs_tree.h>

struct btrfs_fs_info;

/*
 * On-disk layout.
 *
 * Every device carries BTRFS_WIB_NR_SLOTS log blocks of BTRFS_WIB_SLOT_SIZE
 * bytes each, starting at physical offset BTRFS_WIB_OFFSET.  The offset lies
 * inside the first megabyte of the device, which btrfs never hands out to
 * chunks (BTRFS_DEVICE_RANGE_RESERVED) and which only contains the primary
 * superblock at 64KiB.
 *
 * The two slots of a device are written alternately so that a torn write of
 * one slot always leaves the other, older slot intact.  A slot is valid when
 * its magic, fsid and checksum match; recovery uses the union of the newest
 * valid slot of every present device, so any valid slot can only add stripes
 * to recover, never hide one.
 */
#define BTRFS_WIB_OFFSET		SZ_512K
#define BTRFS_WIB_SLOT_SIZE		SZ_4K
#define BTRFS_WIB_NR_SLOTS		2
/*
 * How long btrfs_wib_mark() waits for a full log to drain before failing the
 * write.  Generous: the RMWs that free entries only have to complete their
 * own device IO, so reaching this means something is genuinely stuck.
 */
#define BTRFS_WIB_FULL_TIMEOUT		(60 * HZ)

/* "RI56_WIL" in little endian. */
#define BTRFS_WIB_MAGIC			0x4c49575f36354952ULL

/*
 * Granularity of the log: one bit covers BTRFS_STRIPE_LEN (64KiB) of logical
 * address space, one entry covers 64 such blocks (4MiB), naturally aligned.
 * A full stripe (nr_data * 64KiB, aligned to its own length) therefore maps
 * to nr_data consecutive bits, possibly straddling two entries.
 */
#define BTRFS_WIB_BLOCK_SHIFT		16
#define BTRFS_WIB_BLOCK_SIZE		(1ULL << BTRFS_WIB_BLOCK_SHIFT)
#define BTRFS_WIB_ENTRY_SHIFT		(BTRFS_WIB_BLOCK_SHIFT + 6)
#define BTRFS_WIB_ENTRY_SIZE		(1ULL << BTRFS_WIB_ENTRY_SHIFT)

struct btrfs_wib_disk_entry {
	/* BTRFS_WIB_ENTRY_SIZE aligned logical address. */
	__le64 bytenr;
	/* Bit i set: [bytenr + i * 64K, +64K) has a sub-stripe write in flight. */
	__le64 bitmap;
	/*
	 * Bit i set: a write to that block failed on some device, or the
	 * block could not be fully recovered at the last mount.  Recovery
	 * verifies such a stripe but does not trust its unverifiable
	 * sectors (see btrfs_wib_recover()).
	 */
	__le64 error;
} __packed;

struct btrfs_wib_disk_header {
	/* Checksum (fs csum type) of the block starting after this field. */
	u8 csum[BTRFS_CSUM_SIZE];
	/* metadata_uuid of the filesystem this block belongs to. */
	u8 fsid[BTRFS_FSID_SIZE];
	__le64 magic;
	/* Monotonically increasing per commit. */
	__le64 seq;
	__le32 nr_entries;
	/* BTRFS_WIB_BLOCK_SHIFT of the writer, for future format changes. */
	__le32 block_shift;
	__le64 flags;
	__le64 reserved[6];
} __packed;

#define BTRFS_WIB_MAX_ENTRIES						\
	((BTRFS_WIB_SLOT_SIZE - sizeof(struct btrfs_wib_disk_header)) /	\
	 sizeof(struct btrfs_wib_disk_entry))

/* In-memory entry, mirrors the on-disk one. */
struct btrfs_wib_entry {
	u64 bytenr;
	/* Blocks with a sub-stripe write in flight. */
	u64 bitmap;
	/*
	 * Blocks whose sub-stripe write completed with a device error, whose
	 * log record may not have reached a device with its data flushed, or
	 * whose recovery could not complete: the stripe may be inconsistent
	 * on some device without any crash, keep it logged so that it is
	 * scrubbed at the next mount.  Cleared by a successful recovery, or
	 * by eviction when the log is full.
	 */
	u64 sticky;
	/*
	 * Blocks whose data a failed write left stale on disk: the value that
	 * was acknowledged survives only in the parity.  A checksum would say
	 * the same thing about the sector, and for nodatacow data this is the
	 * only thing that can: without it the next read-modify-write of the
	 * same full stripe reads the stale sector, believes it, and computes a
	 * parity from it -- destroying the copy that still had the
	 * acknowledged content.  See btrfs_wib_stale() and
	 * verify_bio_data_sectors().
	 *
	 * A subset of @sticky.  Not persisted: it lives for the mount that
	 * saw the failure, which is where the read path needs it.  Across a
	 * mount the stripe is still recorded by @sticky and scrubbed.
	 */
	u64 stale;
};

struct btrfs_wib {
	struct btrfs_fs_info *fs_info;

	/*
	 * Protects entries[], snap_seq, seq, enabled and the enable/disable
	 * requests.  Never held across IO.
	 */
	spinlock_t lock;

	/*
	 * Serializes commits (the on-disk writes).  Also protects block,
	 * last and last_ok.
	 */
	struct mutex commit_mutex;

	/*
	 * Woken when an entry becomes free (all its in-flight bits cleared)
	 * and when a commit completes.
	 */
	wait_queue_head_t wait;

	/* Sequence number of the last successful commit. */
	u64 seq;
	/* Sequence number of the last snapshot taken (>= seq). */
	u64 snap_seq;

	/*
	 * True once the log is being persisted.  Marks are always tracked in
	 * memory so that enabling the log at runtime persists everything
	 * that is in flight at that moment.
	 */
	bool enabled;
	/* Enable at the next transaction commit (set without locks held). */
	bool enable_requested;
	/*
	 * Stop persisting once the superblock without the feature flag is
	 * durable: set by the request, armed by the commit that writes such
	 * a superblock, acted upon by the following one.
	 */
	bool disable_requested;
	bool disable_armed;
	/*
	 * A commit sampled enable_requested and is writing the log out.  The
	 * log is not enabled yet, so a disable arriving now cannot express
	 * itself through disable_requested the usual way; this tells it to
	 * do so anyway, and tells the commit not to set the feature flag.
	 */
	bool enable_in_progress;

	/* In-flight sub-stripe writes, bitmap == 0 means the entry is free. */
	struct btrfs_wib_entry entries[BTRFS_WIB_MAX_ENTRIES];

	/* Page sized buffer holding the block being written. */
	void *block;
	/*
	 * Copy of the last block built for a commit, written or not.  Every
	 * device holds this block or an older one that lists a subset of it.
	 */
	void *last;
	/* The last block reached every device it was written to. */
	bool last_ok;
	/*
	 * Snapshot of the set taken before the devices were flushed; a
	 * commit after the flush drops only what finished before it.
	 */
	void *prepared;
	bool prepared_valid;
	/*
	 * The same, for the flush-and-drop path, which takes its own snapshot
	 * before flushing.  It needs a buffer of its own: wib->block is the
	 * scratch that block building writes into, and @prepared belongs to
	 * the transaction commit.
	 */
	void *flushsnap;

	/* IO completion tracking for one commit, commit_mutex held. */
	atomic_t io_pending;
	wait_queue_head_t io_wait;

	/* Dirty regions loaded from disk at mount, waiting for recovery. */
	struct btrfs_wib_entry *pending;
	unsigned int nr_pending;
	unsigned int max_pending;

	/* Statistics, exported through sysfs. */
	atomic64_t stat_marks;
	atomic64_t stat_commits;
	atomic64_t stat_commit_flushes;
	atomic64_t stat_recovered_stripes;
	atomic64_t stat_recovery_errors;
	atomic64_t stat_sticky;
	atomic64_t stat_sticky_evicted;
	atomic64_t stat_commit_errors;
};

int btrfs_wib_alloc(struct btrfs_fs_info *fs_info);
void btrfs_wib_free(struct btrfs_fs_info *fs_info);

int btrfs_wib_load(struct btrfs_fs_info *fs_info);
int btrfs_wib_recover(struct btrfs_fs_info *fs_info, bool log_replay_pending);
int btrfs_wib_recover_after_replay(struct btrfs_fs_info *fs_info);
int btrfs_wib_rw_mount(struct btrfs_fs_info *fs_info, bool log_replay_pending,
		       bool rdonly);

int btrfs_wib_enable(struct btrfs_fs_info *fs_info);
void btrfs_wib_disable(struct btrfs_fs_info *fs_info);
int btrfs_wib_request_enable(struct btrfs_fs_info *fs_info, bool automatic);

int btrfs_wib_mark(struct btrfs_fs_info *fs_info, u64 logical, u64 len);
void btrfs_wib_done(struct btrfs_fs_info *fs_info, u64 logical, u64 len, bool failed);
void btrfs_wib_mark_stale(struct btrfs_fs_info *fs_info, u64 logical, u64 len);
bool btrfs_wib_stale(struct btrfs_fs_info *fs_info, u64 logical);
void btrfs_wib_commit_prepare(struct btrfs_fs_info *fs_info);
int btrfs_wib_commit(struct btrfs_fs_info *fs_info, bool flushed);

/* Helpers exported for the self tests. */
u64 btrfs_wib_range_mask(u64 bytenr, u64 logical, u64 len);
int btrfs_wib_build_block(struct btrfs_wib *wib, void *block, u64 seq, const void *base);
bool btrfs_wib_block_valid(const struct btrfs_fs_info *fs_info, const void *block);
bool btrfs_wib_block_drops(const void *old, const void *new);
int btrfs_wib_add_pending(struct btrfs_wib *wib, u64 bytenr, u64 bitmap, u64 error);
void btrfs_wib_finalize_pending(struct btrfs_wib *wib);
int btrfs_wib_try_mark(struct btrfs_wib *wib, u64 logical, u64 len);
bool btrfs_wib_can_mark(struct btrfs_wib *wib, u64 logical, u64 len);
void btrfs_wib_add_sticky(struct btrfs_fs_info *fs_info, u64 logical, u64 len);
void btrfs_wib_clear_sticky(struct btrfs_fs_info *fs_info, u64 logical, u64 len);

#endif
