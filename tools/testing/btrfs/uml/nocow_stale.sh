#!/bin/bash
# Does the write-intent log's mount-time recovery DESTROY nodatacow data that
# was still recoverable before it ran?
#
#   nocow_stale.sh <kernel> [ndev] [fail-device]
#
# A nodatacow sector carries no checksum, so scrub_verify_one_sector() trusts
# whatever is on the disk and scrub_raid56_parity_stripe() recomputes the
# parity from it.  When a failed write left that sector stale, the parity held
# the only copy of the acknowledged content -- and recovery replaces it with a
# parity computed from the stale sector.
#
# The experiment reads the same blocks three times, always with the device
# holding the stale sectors OMITTED so the read must come from the parity:
#
#   before  after the failed writes, read-only so recovery does not run
#   after   once a read-write mount has run recovery
#
# before=0 and after>0 is the defect: data that the parity could still supply
# is gone once recovery has been.  before>0 means the premise is wrong and the
# parity never held it.
set -u
T=${BTRFS_TEST_DIR:?set BTRFS_TEST_DIR to a scratch directory}
KERNEL=${1:?usage: nocow_stale.sh <kernel> [ndev] [fail-device] [log|nolog]}
NDEV=${2:-4}
FAIL=${3:-1}
# "log"    the write-intent log's mount-time recovery does the scrubbing
# "nolog"  a plain "btrfs scrub" does it, with the log off
# "rmw"    nothing scrubs at all: an ordinary FAULT-FREE write to another
#          column of the same full stripe is what destroys the data
WHO=${4:-log}   # log | nolog | rmw | replay
TAG=nocow-stale-$WHO
PROFILE=raid5:raid1
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p $T/umltest
cp $HERE/init-final3.sh $T/umltest/init-final3.sh
D=$T/umltest/$TAG
rm -rf $D; mkdir -p $D
rm -f $T/umltest/results.$TAG $T/umltest/nocow.bad.*.$TAG
for i in $(seq 0 $((NDEV-1))); do truncate -s 1G $D/disk$i.img; done
ulimit -c 0

boot() {	# mode omit mntdev [extra-env]
	local mode=$1 omit=$2 mntdev=$3 extra="${4:-}" ubds="" d
	for d in $(seq 0 $((NDEV-1))); do
		case " $omit " in *" $d "*) continue;; esac
		ubds="$ubds ubd$d=$D/disk$d.img"
	done
	timeout 1500 $KERNEL mem=1G rootfstype=hostfs rootflags=/ rw \
		init=$T/umltest/init-final3.sh $ubds quiet con=null con0=fd:0,fd:1 \
		BTRFS_TEST_DIR=$T MODE=$mode OPTS=rw PROFILE=$PROFILE TAG=$TAG \
		MNTDEV=$mntdev NDEV=$NDEV FAIL=$FAIL $extra \
		> $D/log.$mode.${omit// /-}${extra:+.${PROBE_SUFFIX:-x}} 2>&1
	echo "boot $mode omit=$omit rc=$?" >> $T/umltest/results.$TAG
}

# The device whose writes fail is also the one omitted for the probes, so the
# stale sectors it holds must be reconstructed from the parity.
MNTPROBE=/dev/ubda; [ "$FAIL" = "0" ] && MNTPROBE=/dev/ubdb

if [ "$WHO" = replay ]; then
	# The after-replay recovery path: error records plus a dirty tree log.
	boot nocow_replay_prep none /dev/ubda
	boot nocow_replay_probe "$FAIL" $MNTPROBE PROBE=before
	boot nocow_replay_recover none /dev/ubda
	boot nocow_replay_probe "$FAIL" $MNTPROBE PROBE=after
	before=$(cat $T/umltest/nocow.replay.before.$TAG 2>/dev/null || echo "?")
	after=$(cat $T/umltest/nocow.replay.after.$TAG 2>/dev/null || echo "?")
	echo "==== $TAG ===="; cat $T/umltest/results.$TAG; echo
	echo "blocks unrecoverable from the parity, device $FAIL omitted:"
	echo "  before the after-replay recovery: $before"
	echo "  after  the after-replay recovery: $after"
	[ "$before" = "?" ] || [ "$after" = "?" ] && { echo "RESULT: INCONCLUSIVE"; exit 2; }
	[ "$before" -gt 0 ] 2>/dev/null && { echo "RESULT: PREMISE WRONG -- the parity did not hold them to begin with"; exit 3; }
	[ "$after" -gt 0 ] 2>/dev/null \
		&& { echo "RESULT: REPRODUCED -- the after-replay recovery destroyed $after block(s)"; exit 1; } \
		|| { echo "RESULT: NOT REPRODUCED -- the data survived the after-replay recovery"; exit 0; }
fi

if [ "$WHO" = rmw ]; then
	# One boot does the whole thing: failed write, heal, then a clean write
	# to the neighbouring column of the same full stripe.
	boot nocow_rmw none /dev/ubda
	boot nocow_rmw_probe "$FAIL" $MNTPROBE
	bad=$(cat $T/umltest/nocow.rmw.$TAG 2>/dev/null || echo "?")
	echo "==== $TAG ===="
	cat $T/umltest/results.$TAG
	echo
	echo "pass-1 blocks unrecoverable from the parity after a clean write to"
	echo "the neighbouring column, device $FAIL omitted: $bad"
	[ "$bad" = "?" ] && { echo "RESULT: INCONCLUSIVE"; exit 2; }
	[ "$bad" -gt 0 ] 2>/dev/null \
		&& { echo "RESULT: REPRODUCED -- a fault-free write destroyed $bad block(s)"; exit 1; } \
		|| { echo "RESULT: NOT REPRODUCED -- the fault-free write left them recoverable"; exit 0; }
fi

PROBE_SUFFIX=before
if [ "$WHO" = nolog ]; then
	boot nocow_stale none /dev/ubda NOLOG=1
else
	boot nocow_stale none /dev/ubda
fi
boot nocow_probe "$FAIL" $MNTPROBE PROBE=before
PROBE_SUFFIX=after
if [ "$WHO" = nolog ]; then
	boot nocow_scrub none /dev/ubda
else
	boot nocow_recover none /dev/ubda
fi
boot nocow_probe "$FAIL" $MNTPROBE PROBE=after

before=$(cat $T/umltest/nocow.bad.before.$TAG 2>/dev/null || echo "?")
after=$(cat $T/umltest/nocow.bad.after.$TAG 2>/dev/null || echo "?")
echo "==== $TAG ===="
cat $T/umltest/results.$TAG
echo
echo "who scrubbed: $WHO"
echo "blocks unrecoverable from the parity, device $FAIL omitted:"
echo "  before recovery: $before"
echo "  after  recovery: $after"
if [ "$before" = "?" ] || [ "$after" = "?" ]; then
	echo "RESULT: INCONCLUSIVE (a boot did not report)"; exit 2
elif [ "$before" = 0 ] && [ "$after" -gt 0 ] 2>/dev/null; then
	echo "RESULT: REPRODUCED -- recovery destroyed $after block(s) the parity could still supply"; exit 1
elif [ "$before" -gt 0 ] 2>/dev/null; then
	echo "RESULT: PREMISE WRONG -- the parity did not hold the data even before recovery"; exit 3
else
	echo "RESULT: NOT REPRODUCED -- recovery left the data recoverable"; exit 0
fi
