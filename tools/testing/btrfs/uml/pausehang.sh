#!/bin/bash
# Does the write-intent log's recovery wedge against the scrub pause protocol?
#
#   pausehang.sh <kernel> [ndev] [fail-device] [delay-ms]
#
# The recovery is kept out of fs_info->scrubs_running on purpose, but the
# scrub code it calls increments fs_info->scrubs_paused.  btrfs_scrub_pause()
# waits for those two to be EQUAL and scrub_pause_off() waits for pause_req to
# reach zero, so a commit arriving while the recovery is inside the protocol
# leaves each waiting on the other.
#
# REMOUNT_RW_DONE  the remount finished: no wedge
# REMOUNT_RW_STUCK the remount never returned
set -u
T=${BTRFS_TEST_DIR:?set BTRFS_TEST_DIR to a scratch directory}
KERNEL=${1:?usage: pausehang.sh <kernel> [ndev] [fail-device] [delay-ms]}
NDEV=${2:-4}; FAIL=${3:-1}; DELAY=${4:-40}
TAG=pausehang
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p $T/umltest
cp $HERE/init-final3.sh $T/umltest/init-final3.sh
D=$T/umltest/$TAG
rm -rf $D; mkdir -p $D; rm -f $T/umltest/results.$TAG $T/umltest/stop.$TAG
for i in $(seq 0 $((NDEV-1))); do truncate -s 1G $D/disk$i.img; done
ulimit -c 0
ubds=""; for d in $(seq 0 $((NDEV-1))); do ubds="$ubds ubd$d=$D/disk$d.img"; done
boot() {
	timeout 900 $KERNEL mem=1G rootfstype=hostfs rootflags=/ rw \
		init=$T/umltest/init-final3.sh $ubds quiet con=null con0=fd:0,fd:1 \
		BTRFS_TEST_DIR=$T MODE=$1 OPTS=rw PROFILE=raid5:raid1 TAG=$TAG \
		MNTDEV=/dev/ubda NDEV=$NDEV FAIL=$FAIL DELAY=$DELAY > $D/log.$1 2>&1
	echo "boot $1 rc=$?" >> $T/umltest/results.$TAG
}
# Two boots: the first leaves recorded stripes on disk, the second mounts
# read-only so the remount is what runs the recovery.
if [ "${VIA:-remount}" = log ]; then
	# The recovery that runs after the transaction kthread is up.
	boot pausehang_log_prep
	boot pausehang_log
else
	boot pausehang_prep
	boot pausehang
fi
echo "==== $TAG ===="
cat $T/umltest/results.$TAG
echo
# A remount that returned having recovered nothing says nothing about the
# wedge: the window never opened.  That is inconclusive, not a pass.
if grep -q "NOTHING_TO_RECOVER" $T/umltest/results.$TAG; then
	echo "RESULT: INCONCLUSIVE -- no stripes were pending, the recovery never ran"
	exit 2
elif grep -qE "REMOUNT_RW_STUCK|MOUNT_STUCK" $T/umltest/results.$TAG; then
	echo "RESULT: WEDGED -- the read-write remount never returned"
	grep -a "blocked for more\|scrub\|D    " $D/log.pausehang | head -12
	exit 1
elif grep -qE "REMOUNT_RW_DONE|MOUNT_DONE" $T/umltest/results.$TAG; then
	echo "RESULT: COMPLETED -- no wedge"; exit 0
else
	echo "RESULT: INCONCLUSIVE -- the remount was never reached"; exit 2
fi
