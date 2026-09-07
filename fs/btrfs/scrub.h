/* SPDX-License-Identifier: GPL-2.0 */

#ifndef BTRFS_SCRUB_H
#define BTRFS_SCRUB_H

#include <linux/types.h>

struct btrfs_fs_info;
struct btrfs_device;
struct btrfs_scrub_progress;

int btrfs_scrub_dev(struct btrfs_fs_info *fs_info, u64 devid, u64 start,
		    u64 end, struct btrfs_scrub_progress *progress,
		    bool readonly, bool is_dev_replace);
int btrfs_raid56_full_stripe_range(struct btrfs_fs_info *fs_info, u64 logical,
				   u64 *full_stripe_start, u64 *full_stripe_len);
int btrfs_scrub_raid56_full_stripe(struct btrfs_fs_info *fs_info,
				   u64 full_stripe_start, bool trusted);
void btrfs_scrub_pause(struct btrfs_fs_info *fs_info);
void btrfs_scrub_continue(struct btrfs_fs_info *fs_info);
int btrfs_scrub_cancel(struct btrfs_fs_info *info);
int btrfs_scrub_cancel_dev(struct btrfs_device *dev);
int btrfs_scrub_progress(struct btrfs_fs_info *fs_info, u64 devid,
			 struct btrfs_scrub_progress *progress);

#endif
