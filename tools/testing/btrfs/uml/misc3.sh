#!/bin/bash
# Single-boot scenarios: misc.sh <kernel> <tag> <mode> <profile> <opts> <ndev>
set -u
T=${BTRFS_TEST_DIR:?set BTRFS_TEST_DIR to a scratch directory}
KERNEL=$1; TAG=$2; MODE=$3; PROFILE=$4; OPTS=$5; NDEV=${6:-4}
D=$T/umltest/$TAG
rm -rf $D; mkdir -p $D
rm -f $T/umltest/results.$TAG $T/umltest/manifest.$TAG $T/umltest/nocow.md5.$TAG $T/umltest/old.md5.$TAG $T/umltest/stop.$TAG
ubds=""
for i in $(seq 0 $((NDEV-1))); do truncate -s 4G $D/disk$i.img; ubds="$ubds ubd$i=$D/disk$i.img"; done
ulimit -c 0
timeout 1500 $KERNEL mem=1G rootfstype=hostfs rootflags=/ rw init=$T/umltest/init-final2.sh $ubds \
	quiet con=null con0=fd:0,fd:1 MODE=$MODE OPTS=$OPTS PROFILE=$PROFILE CRASH=0 TAG=$TAG \
	MNTDEV=/dev/ubda NDEV=$NDEV ${EXTRA:-} > $D/log.$MODE 2>&1
echo "boot $MODE rc=$?" >> $T/umltest/results.$TAG
grep -aE "BUG:|WARNING:|KASAN|lockdep|circular|deadlock|hung task|Oops|INFO: task" $D/log.$MODE | head -n 5 >> $T/umltest/results.$TAG
echo "==== $TAG ===="
cat $T/umltest/results.$TAG
