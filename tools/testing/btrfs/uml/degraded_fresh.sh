#!/bin/bash
# Boot a filesystem that is degraded from the very first mount and write into
# never-written space.  degraded_fresh.sh <kernel> <tag> <profile> <ndev> <omit>
set -u
T=${BTRFS_TEST_DIR:?}; K=$1; TAG=$2; PROFILE=$3; NDEV=${4:-4}; OMIT=${5:-3}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p $T/umltest; cp $HERE/init-final3.sh $T/umltest/init-final3.sh
D=$T/umltest/$TAG; rm -rf $D; mkdir -p $D; rm -f $T/umltest/results.$TAG
ubds=""
for i in $(seq 0 $((NDEV-1))); do
	truncate -s 1G $D/disk$i.img
	[ "$i" = "$OMIT" ] && continue
	ubds="$ubds ubd$i=$D/disk$i.img"
done
ulimit -c 0
timeout 900 $K mem=1G rootfstype=hostfs rootflags=/ rw \
	init=$T/umltest/init-final3.sh $ubds quiet con=null con0=fd:0,fd:1 \
	BTRFS_TEST_DIR=$T MODE=degraded_fresh OPTS=rw PROFILE=$PROFILE CRASH=0 \
	TAG=$TAG MNTDEV=/dev/ubda NDEV=$NDEV > $D/log 2>&1
echo "boot rc=$?" >> $T/umltest/results.$TAG
cat $T/umltest/results.$TAG
