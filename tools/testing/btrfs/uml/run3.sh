#!/bin/bash
# Host-side orchestration of one crash scenario.
#   run.sh <kernel> <tag> <profile data:meta> <mount opts> <crash point> <ndev>
# Boots: prepare (crashes), recover (full mount), then one degraded boot per
# omitted device.  Results land in results.<tag>.
set -u
T=${BTRFS_TEST_DIR:?set BTRFS_TEST_DIR to a scratch directory}
KERNEL=${1:?usage: see README.md}; TAG=$2; PROFILE=$3; OPTS=$4; CRASH=$5; NDEV=${6:-4}
D=$T/umltest/$TAG
rm -rf $D; mkdir -p $D
rm -f $T/umltest/results.$TAG $T/umltest/manifest.$TAG $T/umltest/nocow.md5.$TAG $T/umltest/old.md5.$TAG
for i in $(seq 0 $((NDEV-1))); do truncate -s 1G $D/disk$i.img; done
ulimit -c 0

boot() {
	local mode=$1 omit=$2 mntdev=$3
	local ubds=""
	local d
	for d in $(seq 0 $((NDEV-1))); do
		case " $omit " in *" $d "*) continue;; esac
		ubds="$ubds ubd$d=$D/disk$d.img"
	done
	omit=${omit// /-}
	local extra="${4:-}" suffix="${5:-}"
	timeout 1800 $KERNEL mem=1G rootfstype=hostfs rootflags=/ rw \
		init=$T/umltest/init-final2.sh $ubds quiet con=null con0=fd:0,fd:1 \
		MODE=$mode OPTS=$OPTS PROFILE=$PROFILE CRASH=$CRASH TAG=$TAG \
		MNTDEV=$mntdev NDEV=$NDEV CONVERT=${CONVERT:-} $extra > $D/log.$mode.omit$omit$suffix 2>&1
	echo "boot $mode omit=$omit$suffix rc=$?" >> $T/umltest/results.$TAG
}

boot ${PREPARE_MODE:-prepare} none /dev/ubda
grep -a "crash injection" $D/log.${PREPARE_MODE:-prepare}.omitnone | head -2 >> $T/umltest/results.$TAG
if [ -n "${REGEN_CRASH:-}" ]; then
	# Crash the parity regeneration itself, then recover for real.
	boot recover none /dev/ubda "btrfs.raid56_crash_point=4" .regencrash
	grep -a "crash injection" $D/log.recover.omitnone.regencrash | head -2 >> $T/umltest/results.$TAG
fi
boot ${RECOVER_MODE:-recover} none /dev/ubda
for i in $(seq 0 $((NDEV-1))); do
	# Mount from the first device that is present.
	mnt=/dev/ubda; [ "$i" = "0" ] && mnt=/dev/ubdb
	boot degraded $i $mnt
done
if [ "${PROFILE%%:*}" = "raid6" ]; then
	# RAID6 tolerates two missing devices: try every pair.
	for i in $(seq 0 $((NDEV-1))); do
		for j in $(seq $((i+1)) $((NDEV-1))); do
			mnt=/dev/ubda; [ "$i" = "0" ] && mnt=/dev/ubdb
			[ "$i" = "0" ] && [ "$j" = "1" ] && mnt=/dev/ubdc
			boot degraded "$i $j" $mnt
		done
	done
fi
echo "==== $TAG ===="
cat $T/umltest/results.$TAG
