#!/bin/bash
# Build an aged RAID5/6 filesystem and measure how much of its free space is
# stranded inside vertical stripes that still hold live data.
#   age.sh <kernel> <tag> <profile data:meta> [ndev] [devsize] [target MiB]
# The filesystem is aged inside UML, then read from the host with dump-tree,
# so the measurement never runs against a mounted filesystem.
set -u
T=${BTRFS_TEST_DIR:?set BTRFS_TEST_DIR to a scratch directory}
KERNEL=${1:?usage: age.sh <kernel> <tag> <profile> [ndev] [devsize] [fill]}
TAG=$2; PROFILE=$3; NDEV=${4:-4}; DEVSIZE=${5:-2G}; FILL=${6:-0.75}
HERE=$(cd "$(dirname "$0")" && pwd)
D=$T/umltest/$TAG
rm -rf $D; mkdir -p $D $T/umltest
rm -f $T/umltest/results.$TAG
# Into the per-tag directory, not the shared one: two runs at once would
# otherwise overwrite the scripts under each other, and bash reads an init
# script as it executes it -- the other guest loses its init and panics.
cp $HERE/age-init.sh $HERE/age-workload.py $D/
ubds=""
for i in $(seq 0 $((NDEV-1))); do
	truncate -s $DEVSIZE $D/disk$i.img
	ubds="$ubds ubd$i=$D/disk$i.img"
done
ulimit -c 0
timeout 3600 $KERNEL mem=1G rootfstype=hostfs rootflags=/ rw \
	init=$D/age-init.sh $ubds quiet con=null con0=fd:0,fd:1 \
	BTRFS_TEST_DIR=$T PROFILE=$PROFILE TAG=$TAG SEED=${SEED:-1} \
	ROUNDS=${ROUNDS:-12} \
	FILL=$FILL > $D/log.age 2>&1
echo "boot rc=$?" >> $T/umltest/results.$TAG

echo "==== $TAG ===="
cat $T/umltest/results.$TAG
echo
python3 $HERE/../raid56_row_occupancy.py $D/chunk.txt $D/extent.txt | tee $D/occupancy.txt
