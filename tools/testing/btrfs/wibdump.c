// SPDX-License-Identifier: GPL-2.0
/*
 * Dump what the RAID5/6 write-intent log knows, via
 * BTRFS_IOC_RAID56_STALE_STRIPES.
 *
 *   wibdump <mountpoint> [nr_data] [nr_parity] [bg_start]
 *
 * This is the reference reader for that interface, and the shape a recovery
 * helper would start from.  It prints, per recorded region, which blocks the
 * kernel can NAME as stale -- a write supplied that data column and that
 * column's own write failed, so the acknowledged value is in the parity and
 * not on the disk -- and which are merely suspect, meaning a write there went
 * wrong and nothing can say which member.
 *
 * Given the chunk geometry AND the block group start it also applies the
 * kernel's own repair test, so the two can be compared rather than drifting: a
 * full stripe is repairable when the columns that cannot be believed are no
 * more numerous than the parities that can still be used.  Both are needed:
 * full stripes are aligned to nr_data * 64KiB from the START OF THE BLOCK
 * GROUP, and a log region is aligned to 4MiB, so without the block group start
 * the two grids do not line up and any per-stripe verdict is grouping columns
 * that are not in the same stripe.  Guessing there would be exactly the thing
 * this interface exists to avoid, so with no block group start the verdict is
 * simply not printed.  A real helper reads both from the chunk tree, then maps
 * each
 * affected stripe to files with BTRFS_IOC_LOGICAL_INO and BTRFS_IOC_INO_PATHS
 * and compute both candidate values from the devices -- without writing
 * anything until a human or a format-aware check has chosen.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <stdint.h>

#define BTRFS_IOCTL_MAGIC 0x94

struct wib_entry {
	uint64_t bytenr;
	uint64_t bitmap;
	uint64_t sticky;
	uint64_t stale;
	uint64_t stale_par;
	uint64_t gen;
};

struct wib_args {
	uint64_t bytenr;
	uint64_t buf_size;
	uint64_t flags;
	uint32_t nr_entries;
	uint32_t reserved;
	uint8_t buf[];
};

#define BTRFS_IOC_RAID56_STALE_STRIPES _IOWR(BTRFS_IOCTL_MAGIC, 67, struct wib_args)

#define BLOCK_SIZE	(64ULL << 10)
#define NR_BLOCKS	64
#define MAX_ENTRIES	165

/*
 * Index of the first block in this 4MiB region that starts a full stripe.
 * Full stripes tile the block group from its start, so the two grids only
 * line up once the block group start is known.  Returns -1 if none does.
 */
static int first_stripe_block(uint64_t bytenr, unsigned long long bg_start,
			      int nr_data)
{
	const uint64_t fstripe = (uint64_t)nr_data * BLOCK_SIZE;
	uint64_t off, first;

	if (bytenr < bg_start)
		return -1;
	off = bytenr - bg_start;
	first = (off % fstripe) ? (fstripe - (off % fstripe)) : 0;
	if (first % BLOCK_SIZE)
		return -1;
	if (first / BLOCK_SIZE >= NR_BLOCKS)
		return -1;
	return (int)(first / BLOCK_SIZE);
}

int main(int argc, char **argv)
{
	const int nr_data = argc > 2 ? atoi(argv[2]) : 0;
	const int nr_parity = argc > 3 ? atoi(argv[3]) : 1;
	const int have_bg = argc > 4;
	const unsigned long long bg_start = have_bg ? strtoull(argv[4], NULL, 0) : 0;
	unsigned long long total = 0, named = 0, unknown = 0;
	unsigned long long repairable = 0, ambiguous = 0;
	struct wib_args *args;
	struct wib_entry *e;
	size_t bufsz;
	int fd, ret = 0;

	if (argc < 2) {
		fprintf(stderr, "usage: wibdump <mountpoint> [nr_data] [nr_parity] [bg_start]\n");
		return 2;
	}
	fd = open(argv[1], O_RDONLY);
	if (fd < 0) {
		perror("open");
		return 2;
	}

	bufsz = sizeof(*args) + MAX_ENTRIES * sizeof(*e);
	args = calloc(1, bufsz);
	if (!args) {
		perror("calloc");
		close(fd);
		return 2;
	}
	e = (struct wib_entry *)args->buf;

	for (;;) {
		args->buf_size = MAX_ENTRIES * sizeof(*e);
		args->flags = 0;
		args->reserved = 0;
		if (ioctl(fd, BTRFS_IOC_RAID56_STALE_STRIPES, args) < 0) {
			if (errno == EOPNOTSUPP) {
				printf("WIBDUMP unsupported: no write-intent log\n");
				goto out;
			}
			perror("ioctl");
			ret = 2;
			goto out;
		}
		if (args->nr_entries == 0)
			break;

		for (unsigned int i = 0; i < args->nr_entries; i++) {
			total++;
			for (int b = 0; b < NR_BLOCKS; b++) {
				const uint64_t bit = 1ULL << b;

				if (e[i].stale & bit) {
					named++;
					printf("KNOWN    %llu gen=%llu data column stale: the acknowledged value is in the parity\n",
					       (unsigned long long)(e[i].bytenr + b * BLOCK_SIZE),
					       (unsigned long long)e[i].gen);
				} else if (e[i].sticky & bit) {
					unknown++;
					printf("UNKNOWN  %llu gen=%llu a write went wrong here, member unidentified\n",
					       (unsigned long long)(e[i].bytenr + b * BLOCK_SIZE),
					       (unsigned long long)e[i].gen);
				}
			}
			/*
			 * The kernel's own test, applied to each full stripe
			 * this region covers.  Only meaningful with the
			 * geometry, which a real helper reads from the chunk
			 * tree.
			 */
			if (nr_data <= 0 || !have_bg)
				continue;
			for (int b = first_stripe_block(e[i].bytenr, bg_start, nr_data);
			     b >= 0 && b + nr_data <= NR_BLOCKS; b += nr_data) {
				uint64_t cols = (e[i].stale >> b) &
						((nr_data >= 64) ? ~0ULL : ((1ULL << nr_data) - 1));
				int holes = __builtin_popcountll(cols);
				int good_par = 0;

				if (!holes)
					continue;
				for (int p = 0; p < nr_parity; p++)
					if (!(e[i].stale_par & (1ULL << (b + p))))
						good_par++;
				if (holes <= good_par) {
					repairable++;
					printf("  stripe %llu REPAIRABLE  %d named column(s), %d usable parity\n",
					       (unsigned long long)(e[i].bytenr + b * BLOCK_SIZE),
					       holes, good_par);
				} else {
					ambiguous++;
					printf("  stripe %llu AMBIGUOUS   %d named column(s), %d usable parity -- for a human\n",
					       (unsigned long long)(e[i].bytenr + b * BLOCK_SIZE),
					       holes, good_par);
				}
			}
		}
	}
	printf("WIBDUMP regions=%llu known=%llu unknown=%llu repairable=%llu ambiguous=%llu\n",
	       total, named, unknown, repairable, ambiguous);
out:
	free(args);
	close(fd);
	return ret;
}
