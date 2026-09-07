#!/bin/bash
# Degraded-at-crash scenario: prepare a fs, then omit device FAIL, write and
# crash while degraded, then verify with the device still missing and with
# it back (stale).   degraded.sh <kernel> <tag> <profile> <opts> <crash> <ndev> <fail>
set -u
T=${BTRFS_TEST_DIR:?set BTRFS_TEST_DIR to a scratch directory}
KERNEL=$1; TAG=$2; PROFILE=$3; OPTS=$4; CRASH=$5; NDEV=$6; FAIL=$7
D=$T/umltest/$TAG
rm -rf $D; mkdir -p $D; rm -f $T/umltest/results.$TAG $T/umltest/manifest.$TAG $T/umltest/nocow.md5.$TAG $T/umltest/old.md5.$TAG
for i in $(seq 0 $((NDEV-1))); do truncate -s 1G $D/disk$i.img; done
ulimit -c 0
boot() {
	local mode=$1 omit=$2 mntdev=$3 extra="${4:-}" ubds="" d
	for d in $(seq 0 $((NDEV-1))); do
		case " $omit " in *" $d "*) continue;; esac
		ubds="$ubds ubd$d=$D/disk$d.img"
	done
	timeout 1800 $KERNEL mem=1G rootfstype=hostfs rootflags=/ rw init=$T/umltest/init-final2.sh $ubds \
		quiet con=null con0=fd:0,fd:1 MODE=$mode OPTS=$OPTS PROFILE=$PROFILE CRASH=99 TAG=$TAG \
		MNTDEV=$mntdev NDEV=$NDEV $extra > $D/log.$mode.omit${omit// /-} 2>&1
	echo "boot $mode omit=$omit rc=$?" >> $T/umltest/results.$TAG
}
# prepare with CRASH=99 (never fires: only 1..4 are used) -> clean fs with 'old'
boot prepare none /dev/ubda
mnt=/dev/ubda; [ "$FAIL" = "0" ] && mnt=/dev/ubdb
boot degraded_write $FAIL $mnt "CRASH=$CRASH"
grep -a "crash injection" $D/log.degraded_write.omit$FAIL | head -2 >> $T/umltest/results.$TAG
# recovery with the device still missing
boot degraded_verify $FAIL $mnt "OMITTED=$FAIL"
# the device comes back (stale): recovery again, then verify, then lose another device
boot degraded_verify none /dev/ubda
for o in $(seq 0 $((NDEV-1))); do
	[ "$o" = "$FAIL" ] && continue
	m=/dev/ubda; [ "$o" = "0" ] && m=/dev/ubdb
	boot degraded_verify $o $m "OMITTED=$o"
done
echo "==== $TAG ===="; cat $T/umltest/results.$TAG
