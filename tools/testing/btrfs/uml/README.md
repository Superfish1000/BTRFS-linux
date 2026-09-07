# RAID5/6 crash and fault-injection test rig

Boots a User Mode Linux kernel against image files or device-mapper devices,
drives a scenario inside it, and checks the filesystem from the outside. Used
to verify the RAID5/6 write-intent log and the integrity fixes: it can inject a
crash into the middle of a stripe write, fail or detach a device, and confirm
what a committed file reads back as afterwards.

## Setting up

Everything is driven by `BTRFS_TEST_DIR`, a scratch directory holding the
kernels, btrfs-progs and per-scenario disk images. Nothing is written inside
the kernel source tree.

    export BTRFS_TEST_DIR=/var/tmp/btrfs-test
    mkdir -p $BTRFS_TEST_DIR/umltest

Build two UML kernels from this source tree. The scenarios that inject a crash
need `CONFIG_BTRFS_DEBUG` for the `btrfs.raid56_crash_point` module parameter,
and the self-test boot needs `CONFIG_BTRFS_FS_RUN_SANITY_TESTS`:

    make ARCH=um O=$BTRFS_TEST_DIR/uml-fast defconfig
    # enable: BTRFS_FS=y BTRFS_DEBUG=y BTRFS_FS_RUN_SANITY_TESTS=y
    #         BLK_DEV_UBD=y BLK_DEV_DM=y DM_FLAKEY=y HOSTFS=y PROVE_LOCKING=y
    make ARCH=um O=$BTRFS_TEST_DIR/uml-fast -j$(nproc) linux

A second kernel with `KASAN=y` (as `$BTRFS_TEST_DIR/uml`) is worth having for
the device-failure scenarios; it is roughly three times slower.

btrfs-progs must be built and installed under `$BTRFS_TEST_DIR/progs-install`,
because the guest runs the host filesystem through hostfs and uses that copy.

## Running a scenario

`run3.sh` boots a scenario, then remounts once per omitted device so the
committed data is checked with each device missing in turn:

    ./run3.sh $BTRFS_TEST_DIR/uml-fast/linux r5-crash raid5:raid1 rw 1 4

Arguments are kernel, tag, `data:metadata` profiles, mount options, crash
point, and device count. Results land in `$BTRFS_TEST_DIR/umltest/results.<tag>`.

`PREPARE_MODE` selects what the first boot does. Beyond the default sub-stripe
write, `prepare_fsync` leaves data referenced only by the tree log, and
`inplace` overwrites a nodatacow file in place.

## Crash points

With `CONFIG_BTRFS_DEBUG`, `btrfs.raid56_crash_point` injects a failure into
the next recorded write:

| Value | Effect |
|-------|--------|
| 1 | drop the P/Q writes, then panic once the data writes land |
| 2 | drop the data writes, then panic once P/Q land |
| 3 | drop the P/Q writes, no panic |
| 4 | panic in the next parity scrub before its write |

## The other scripts

| Script | What it does |
|--------|--------------|
| `dmfail34.sh` | device-mapper faults: `detach` fails every I/O, `flakey` fails only writes |
| `degraded23.sh` | writes and crashes while a device is already missing, then verifies with it back |
| `stress23.sh` | concurrent fsync writers, SIGKILL at a random moment, then verifies every file whose fsync returned |
| `staleq.sh` | leaves a sector stale behind an accepted write, then reads it back |
| `misc3.sh` | single-boot scenarios: replace, convert, toggle, scrub, writers |
| `selftest.sh` | boots and reports the in-kernel btrfs self-tests |

`init-final3.sh` runs as init inside the guest and holds every scenario; the
host scripts only choose one and pass parameters on the kernel command line.
