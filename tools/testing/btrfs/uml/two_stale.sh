#!/bin/bash
# Does acting on the write-intent log's stale record make reads WORSE than not
# having the record at all?
#
#   two_stale.sh <kernel> [ndev]
#
# The read path treats a sector the log records as stale the way it treats one
# that failed its checksum: rebuild it from the parity rather than believe it.
# The state-machine model (tools/testing/btrfs/scrub_policy_model.py
# --all-readers) says a version that does that unconditionally hands back a
# value nothing ever committed in 6835 of 14446 RAID5 states -- states where
# the plain upstream read returns the committed content.
#
# This builds one of those states with real devices: two devices failing their
# writes, and each overwrite spanning two data columns of one full stripe, so
# the write takes two faults, RAID5 refuses it, and the log still records both
# columns stale.  A reader that asks for two reconstructions out of one parity
# gets garbage or an error; upstream would have returned the old content.
#
# Runs it twice: once with the fix, once with raid56_stale_read_legacy=1 which
# restores the unconditional behaviour.  A pass with the fix means nothing
# unless the control fails.
set -u
T=${BTRFS_TEST_DIR:?set BTRFS_TEST_DIR to a scratch directory}
KERNEL=${1:?usage: two_stale.sh <kernel> [ndev]}
NDEV=${2:-6}
TAG=two-stale
PROFILE=raid5:raid1
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p $T/umltest
cp $HERE/init-final3.sh $T/umltest/init-final3.sh
D=$T/umltest/$TAG
rm -rf $D; mkdir -p $D
rm -f $T/umltest/results.$TAG $T/umltest/nocow.twostale.*.$TAG
for i in $(seq 0 $((NDEV-1))); do truncate -s 1G $D/disk$i.img; done
ulimit -c 0

boot() {	# legacy
	local legacy=$1 ubds="" d
	for d in $(seq 0 $((NDEV-1))); do ubds="$ubds ubd$d=$D/disk$d.img"; done
	timeout 1800 $KERNEL mem=1G rootfstype=hostfs rootflags=/ rw \
		init=$T/umltest/init-final3.sh $ubds quiet con=null con0=fd:0,fd:1 \
		BTRFS_TEST_DIR=$T MODE=nocow_two_stale OPTS=rw PROFILE=$PROFILE \
		TAG=$TAG MNTDEV=/dev/mapper/d0 NDEV=$NDEV FAIL=1 LEGACY=$legacy \
		> $D/log.legacy$legacy 2>&1
	local rc=$?
	echo "boot legacy=$legacy rc=$rc" >> $T/umltest/results.$TAG
	[ $rc = 124 ] && echo "SETUP FAILURE: boot legacy=$legacy timed out" >&2
	grep -h "NOCOW_TWO_STALE\|overwrites:" $D/log.legacy$legacy | sed "s/^/  [legacy=$legacy] /"
}

echo "== with the fix =="
boot 0
echo "== control: raid56_stale_read_legacy=1 =="
boot 1

read -r fix_g fix_e < $T/umltest/nocow.twostale.0.$TAG 2>/dev/null || { fix_g=?; fix_e=?; }
read -r ctl_g ctl_e < $T/umltest/nocow.twostale.1.$TAG 2>/dev/null || { ctl_g=?; ctl_e=?; }
echo
cat $T/umltest/results.$TAG
echo
echo "                garbage  ioerr"
echo "  with fix        $fix_g      $fix_e"
echo "  legacy control  $ctl_g      $ctl_e"
echo
case "$fix_g$fix_e$ctl_g$ctl_e" in
*'?'*) echo "RESULT: INCONCLUSIVE -- a boot did not report"; exit 2;;
esac
if [ $((ctl_g + ctl_e)) -eq 0 ]; then
	echo "RESULT: INCONCLUSIVE -- the control did not reproduce the defect, so"
	echo "        a clean result with the fix proves nothing"
	exit 2
fi
if [ $((fix_g + fix_e)) -gt 0 ]; then
	echo "RESULT: FAIL -- the fix still returns garbage or fails reads"
	exit 1
fi
echo "RESULT: PASS -- control $((ctl_g + ctl_e)) bad, fixed 0"
