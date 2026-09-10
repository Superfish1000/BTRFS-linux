#!/bin/bash
# Does a plain "btrfs scrub" AFTER A REBOOT still destroy nodatacow data that
# the parity could supply?
#
#   nocow_persist.sh <kernel> [ndev] [fail-device]
#
# The write-intent log records which data blocks a failed write left stale.
# That record used to live only in memory, so it did not survive an unmount --
# and a scrub run after the next mount had nothing to consult, trusted the
# stale sector for want of a checksum, and recomputed the parity from it,
# destroying the only copy of what was acknowledged.
#
# An exhaustive model of the same decision
# (tools/testing/btrfs/scrub_policy_model.py) prices that at 1488 of 8386
# RAID5 states and 6291 of 41791 RAID6 states destroyed -- which is upstream's
# own score, i.e. the scrub fix is worth nothing across a mount without the
# record.  This is the physical version of that claim.
#
# Three boots per arm:
#   prep    build the state with a device failing writes, then unmount CLEANLY
#   scrub   mount fresh, let recovery run, then run a plain user scrub
#   probe   mount ro,degraded with the failing device OMITTED, so every one of
#           those blocks must come from the parity, and count the bad ones
#
# Runs both arms.  The control sets raid56_stale_no_persist=1 during prep, so
# the log is written exactly as the format did before it carried the record.
# A clean result in the fixed arm means nothing unless the control fails.
set -u
T=${BTRFS_TEST_DIR:?set BTRFS_TEST_DIR to a scratch directory}
KERNEL=${1:?usage: nocow_persist.sh <kernel> [ndev] [fail-device]}
NDEV=${2:-4}
FAIL=${3:-1}
PROFILE=raid5:raid1
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p $T/umltest
cp $HERE/init-final3.sh $T/umltest/init-final3.sh
ulimit -c 0

# The device whose writes fail is also the one omitted for the probe.
MNTPROBE=/dev/ubda; [ "$FAIL" = "0" ] && MNTPROBE=/dev/ubdb

arm() {	# nopersist -> echoes "<bad>"
	local nopersist=$1 tag=nocow-persist-$1 d ubds="" omit
	local D=$T/umltest/$tag
	rm -rf $D; mkdir -p $D
	rm -f $T/umltest/results.$tag $T/umltest/nocow.bad.after.$tag
	for i in $(seq 0 $((NDEV-1))); do truncate -s 1G $D/disk$i.img; done

	boot() {	# mode omit mntdev [extra]
		local mode=$1 omit=$2 mntdev=$3 extra="${4:-}"
		ubds=""
		for d in $(seq 0 $((NDEV-1))); do
			case " $omit " in *" $d "*) continue;; esac
			ubds="$ubds ubd$d=$D/disk$d.img"
		done
		timeout 1500 $KERNEL mem=1G rootfstype=hostfs rootflags=/ rw \
			init=$T/umltest/init-final3.sh $ubds quiet con=null con0=fd:0,fd:1 \
			BTRFS_TEST_DIR=$T MODE=$mode OPTS=rw PROFILE=$PROFILE TAG=$tag \
			MNTDEV=$mntdev NDEV=$NDEV FAIL=$FAIL $extra \
			> $D/log.$mode 2>&1
		echo "boot $mode omit=$omit rc=$?" >> $T/umltest/results.$tag
	}

	boot nocow_persist_prep  none /dev/mapper/d0 "NOPERSIST=$nopersist"
	boot nocow_persist_scrub none /dev/mapper/d0
	boot nocow_probe "$FAIL" $MNTPROBE PROBE=after
	cat $T/umltest/nocow.bad.after.$tag 2>/dev/null || echo "?"
}

sticky_after() { cat $T/umltest/nocow.sticky.nocow-persist-$1 2>/dev/null || echo "?"; }

echo "== with the record persisted =="
fixed=$(arm 0)
grep -hE 'overwrites:|scrub:|NOCOW_DIRECT|scrub_skipped_stale' \
	$T/umltest/nocow-persist-0/log.* 2>/dev/null | sed 's/^/  /' | head -8
echo "== control: raid56_stale_no_persist=1 =="
ctl=$(arm 1)
grep -hE 'overwrites:|NOT be persisted|NOCOW_DIRECT' \
	$T/umltest/nocow-persist-1/log.* 2>/dev/null | sed 's/^/  /' | head -8

echo
echo "blocks unrecoverable from the parity after a post-reboot scrub,"
echo "device $FAIL omitted:"
echo "  record persisted : $fixed"
echo "  control (not)    : $ctl"
echo
case "$fixed$ctl" in *'?'*) echo "RESULT: INCONCLUSIVE -- a boot did not report"; exit 2;; esac
if [ "$ctl" -eq 0 ] 2>/dev/null; then
	echo "RESULT: INCONCLUSIVE -- the control destroyed nothing, so a clean"
	echo "        result with the record persisted proves nothing"
	exit 2
fi
if [ "$fixed" -gt 0 ] 2>/dev/null; then
	echo "RESULT: FAIL -- the scrub still destroyed $fixed block(s)"
	exit 1
fi

# Surviving is not the same as repaired.  The record must be RETIRED: nothing
# else ever clears one, so a stripe still recorded after a scrub is a stripe
# whose redundancy is never restored.
fixed_sticky=$(sticky_after 0)
echo "records still held after the scrub: $fixed_sticky"
if [ "$fixed_sticky" = "?" ]; then
	echo "RESULT: INCONCLUSIVE -- the scrub boot did not report its record count"
	exit 2
fi
if [ "$fixed_sticky" -ne 0 ] 2>/dev/null; then
	echo "RESULT: FAIL -- the data survived but $fixed_sticky record(s) were not"
	echo "        retired, so the parity of those stripes was never regenerated"
	exit 1
fi
echo "RESULT: PASS -- control destroyed $ctl, persisted destroyed 0, all records retired"
