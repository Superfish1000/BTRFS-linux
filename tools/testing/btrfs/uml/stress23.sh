#!/bin/bash
# Chaos test: concurrent fsync writers, SIGKILL of the UML process at a random
# time, then a full (recovery) mount and degraded verification of every file
# whose fsync had returned.
#   stress.sh <kernel> <tag> <profile> <opts> <ndev> <iterations>
set -u
T=${BTRFS_TEST_DIR:?set BTRFS_TEST_DIR to a scratch directory}
KERNEL=$1; TAG=$2; PROFILE=$3; OPTS=$4; NDEV=${5:-4}; ITER=${6:-3}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p $T/umltest
cp $HERE/init-final3.sh $T/umltest/init-final3.sh
cp $HERE/../raid56_wib_dump.py $T/umltest/ 2>/dev/null || true
D=$T/umltest/$TAG
rm -rf $D; mkdir -p $D
rm -f $T/umltest/results.$TAG
ulimit -c 0
ubds_for() {
	local omit="$1" ubds=""
	for i in $(seq 0 $((NDEV-1))); do
		case " $omit " in *" $i "*) continue;; esac
		ubds="$ubds ubd$i=$D/disk$i.img"
	done
	echo $ubds
}
common="mem=1G rootfstype=hostfs rootflags=/ rw init=$T/umltest/init-final3.sh quiet con=null con0=fd:0,fd:1 BTRFS_TEST_DIR=$T OPTS=$OPTS PROFILE=$PROFILE TAG=$TAG NDEV=$NDEV CRASH=0"
for it in $(seq 1 $ITER); do
	for i in $(seq 0 $((NDEV-1))); do rm -f $D/disk$i.img; truncate -s 2G $D/disk$i.img; done
	$KERNEL $common $(ubds_for none) MODE=stress MNTDEV=/dev/ubda > $D/log.stress.$it 2>&1 &
	pid=$!
	for w in $(seq 1 900); do grep -aq STRESS_START $D/log.stress.$it && break; sleep 1; done
	if ! grep -aq STRESS_START $D/log.stress.$it; then
		# mkfs/mount did not finish (slow KASAN kernel under load): not a valid iteration.
		pkill -9 -P $pid 2>/dev/null; kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null
		echo "iter $it: STRESS_NOT_STARTED within 900s, skipped" >> $T/umltest/results.$TAG
		continue
	fi
	delay=$(( (RANDOM % 20000) + 8000 ))
	usleep $((delay * 1000)) 2>/dev/null || sleep $(awk "BEGIN{print $delay/1000}")
	pkill -9 -P $pid 2>/dev/null; kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null
	n=$(wc -l < $T/umltest/manifest.$TAG)
	echo "iter $it: killed after ${delay}ms, $n files fsynced" >> $T/umltest/results.$TAG
	timeout 600 $KERNEL $common $(ubds_for none) MODE=verify MNTDEV=/dev/ubda > $D/log.verify.$it 2>&1
	grep -a "VERIFY\|BAD\|write-intent log:" $D/log.verify.$it | sed "s/^/  full: /" >> $T/umltest/results.$TAG
	for o in $(seq 0 $((NDEV-1))); do
		mnt=/dev/ubda; [ "$o" = "0" ] && mnt=/dev/ubdb
		timeout 600 $KERNEL $common $(ubds_for $o) MODE=verify MNTDEV=$mnt OMITTED=$o > $D/log.verify.$it.omit$o 2>&1
		grep -a "VERIFY\|BAD\|MOUNT_FAIL" $D/log.verify.$it.omit$o | sed "s/^/  omit$o: /" >> $T/umltest/results.$TAG
	done
done
echo "==== $TAG ===="
cat $T/umltest/results.$TAG
