#!/bin/bash
# stale-P RAID6 test: prepare on one boot, verify degraded on the next.
set -u
T=${BTRFS_TEST_DIR:?set BTRFS_TEST_DIR to a scratch directory}
KERNEL=$1; TAG=$2; FAIL=$3; NDEV=5
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p $T/umltest
cp $HERE/init-final3.sh $T/umltest/init-final3.sh
cp $HERE/../raid56_wib_dump.py $T/umltest/ 2>/dev/null || true
D=$T/umltest/$TAG
rm -rf $D; mkdir -p $D; rm -f $T/umltest/results.$TAG $T/umltest/*.md5.$TAG
for i in $(seq 0 $((NDEV-1))); do truncate -s 1G $D/disk$i.img; done
ulimit -c 0
boot() {
	local mode=$1 omit=$2 ubds="" d
	for d in $(seq 0 $((NDEV-1))); do
		case " $omit " in *" $d "*) continue;; esac
		ubds="$ubds ubd$d=$D/disk$d.img"
	done
	timeout 1800 $KERNEL mem=1G rootfstype=hostfs rootflags=/ rw \
		init=$T/umltest/init-final3.sh $ubds quiet con=null con0=fd:0,fd:1 BTRFS_TEST_DIR=$T \
		MODE=$mode OPTS=rw PROFILE=raid6:raid6 CRASH=0 TAG=$TAG \
		MNTDEV=/dev/ubda NDEV=$NDEV FAIL=$FAIL > $D/log.$mode.omit${omit// /-} 2>&1
	echo "boot $mode omit=$omit rc=$?" >> $T/umltest/results.$TAG
}
boot stale_parity none
# Lose a data device other than the one that had write errors.
for o in 0 1 2 3 4; do [ "$o" = "$FAIL" ] && continue; boot stale_parity_verify $o; break; done
echo "==== $TAG ===="; cat $T/umltest/results.$TAG
