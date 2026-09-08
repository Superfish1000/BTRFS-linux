#!/bin/bash
# Recreate the test rig in $BTRFS_TEST_DIR from nothing: the UML kernel with
# the options the scenarios need, and the btrfs-progs the guest runs through
# hostfs.  The rig lives outside the source tree in a scratch directory, so it
# does not survive a wiped /var/tmp -- and a missing rig is not obvious from
# the outside: make(1) fails on the absent .config and every scenario then
# fails for want of a kernel, which reads like a pile of regressions.  Running
# this is the answer to that.
#
#   BTRFS_TEST_DIR=/var/tmp/btrfs-test ./setup.sh [build-dir-name]
#
# Idempotent: an existing kernel config is updated rather than replaced, and
# btrfs-progs is only rebuilt if it is not installed.
set -eu
T=${BTRFS_TEST_DIR:?set BTRFS_TEST_DIR to a scratch directory}
NAME=${1:-uml-verify}
BUILD=$T/$NAME
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../../.." && pwd)
PROGS_REPO=${BTRFS_PROGS_REPO:-https://github.com/kdave/btrfs-progs}

mkdir -p $T/umltest $BUILD

echo "== kernel config ($BUILD) =="
# CONFIG_BTRFS_DEBUG carries the raid56_crash_point module parameter the crash
# scenarios inject through, RUN_SANITY_TESTS carries the write-intent log self
# tests, DM_FLAKEY the device that fails every write, and PROVE_LOCKING catches
# the lock ordering the log adds.  defconfig has none of them.
[ -f $BUILD/.config ] || make -C $REPO ARCH=um O=$BUILD defconfig
$REPO/scripts/config --file $BUILD/.config \
	-e BTRFS_FS -e BTRFS_DEBUG -e BTRFS_FS_RUN_SANITY_TESTS \
	-e BTRFS_FS_POSIX_ACL -e BLK_DEV_UBD -e HOSTFS \
	-e MD -e BLK_DEV_DM -e DM_FLAKEY -e PROVE_LOCKING
make -C $REPO ARCH=um O=$BUILD olddefconfig > /dev/null

# scripts/config edits the file but cannot enable an option whose dependencies
# are unmet, and olddefconfig then drops it again -- silently.  Every one of
# these changes what a scenario actually exercises, so check rather than trust.
missing=
for opt in BTRFS_FS BTRFS_DEBUG BTRFS_FS_RUN_SANITY_TESTS BLK_DEV_UBD \
	   HOSTFS BLK_DEV_DM DM_FLAKEY PROVE_LOCKING; do
	grep -q "^CONFIG_$opt=y" $BUILD/.config || missing="$missing $opt"
done
if [ -n "$missing" ]; then
	echo "  config is missing:$missing" >&2
	exit 1
fi
echo "  all required options set"

echo "== kernel =="
make -C $REPO ARCH=um O=$BUILD -j$(nproc) linux > $T/setup-kernel.log 2>&1 || {
	tail -20 $T/setup-kernel.log >&2; exit 1; }
test -x $BUILD/linux
echo "  $BUILD/linux"

echo "== btrfs-progs =="
if [ -x $T/progs-install/bin/mkfs.btrfs ]; then
	echo "  already installed"
else
	[ -d $T/progs-src ] || git clone --depth 1 $PROGS_REPO $T/progs-src
	cd $T/progs-src
	# The guest only ever runs mkfs/check/inspect on image files, so the
	# compression and python bindings are dead weight and pull in headers
	# the container may not have.
	./autogen.sh > $T/setup-progs.log 2>&1
	./configure --prefix=$T/progs-install --disable-documentation \
		--disable-zstd --disable-lzo --disable-python \
		--disable-backtrace >> $T/setup-progs.log 2>&1
	make -j$(nproc) >> $T/setup-progs.log 2>&1
	make install >> $T/setup-progs.log 2>&1
	echo "  $T/progs-install/bin"
fi

echo "rig ready: BTRFS_TEST_DIR=$T ./regress.sh $BUILD"
