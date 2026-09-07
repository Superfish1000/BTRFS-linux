#!/bin/bash
# Device-mapper failure scenarios (detach / flakey) followed by recovery and
# degraded verification.   dmfail.sh <kernel> <tag> <mode> <profile> <opts> <ndev> <fail>
set -u
T=${BTRFS_TEST_DIR:?set BTRFS_TEST_DIR to a scratch directory}
KERNEL=$1; TAG=$2; MODE=$3; PROFILE=$4; OPTS=$5; NDEV=$6; FAIL=$7
D=$T/umltest/$TAG
rm -rf $D; mkdir -p $D; rm -f $T/umltest/results.$TAG $T/umltest/stop.$TAG $T/umltest/manifest.$TAG $T/umltest/nocow.md5.$TAG $T/umltest/old.md5.$TAG
for i in $(seq 0 $((NDEV-1))); do truncate -s 1G $D/disk$i.img; done
ulimit -c 0
boot() {
	local mode=$1 omit=$2 mntdev=$3 extra="${4:-}" ubds="" d
	for d in $(seq 0 $((NDEV-1))); do
		case " $omit " in *" $d "*) continue;; esac
		ubds="$ubds ubd$d=$D/disk$d.img"
	done
	timeout 1500 $KERNEL mem=1G rootfstype=hostfs rootflags=/ rw init=$T/umltest/init-final3.sh $ubds \
		quiet con=null con0=fd:0,fd:1 MODE=$mode OPTS=$OPTS PROFILE=$PROFILE CRASH=1 TAG=$TAG \
		MNTDEV=$mntdev NDEV=$NDEV FAIL=$FAIL $extra > $D/log.$mode.omit${omit// /-} 2>&1
	echo "boot $mode omit=$omit rc=$?" >> $T/umltest/results.$TAG
}
boot $MODE none /dev/ubda
grep -a "crash injection\|WATCHDOG\|blocked for more" $D/log.$MODE.omitnone | head -3 >> $T/umltest/results.$TAG
boot recover none /dev/ubda
for o in $(seq 0 $((NDEV-1))); do
	m=/dev/ubda; [ "$o" = "0" ] && m=/dev/ubdb
	boot degraded $o $m
done
echo "==== $TAG ===="; cat $T/umltest/results.$TAG
