#!/bin/bash
# Runs as init inside UML.  Makes a RAID5/6 filesystem across the ubd
# devices, ages it with age-workload.py, and unmounts cleanly.  The host
# then reads the result with dump-tree; nothing is measured in here.
#   PROFILE  data:metadata profiles, e.g. raid5:raid1
#   SEED     workload seed
#   TARGET   MiB to write
#   ROUNDS   aging rounds
#   TAG      result file suffix
T=${BTRFS_TEST_DIR:?set BTRFS_TEST_DIR to a scratch directory}
export PATH=$T/progs-install/bin:/usr/sbin:/usr/bin:/sbin:/bin
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
RES=$T/umltest/results.$TAG
MNT=/mnt/umltest
mkdir -p $MNT
log() { echo "AGE: $*"; echo "$*" >> $RES; }

DPROF=${PROFILE%%:*}
MPROF=${PROFILE##*:}
DEVS=$(ls /dev/ubd[a-z] 2>/dev/null | tr '\n' ' ')
log "devices: $DEVS"

# Dump blocked tasks if a step wedges, so a hang is diagnosable from the log
# instead of looking like a slow run.
( sleep ${WATCHDOG:-900}; echo 8 > /proc/sys/kernel/printk
  echo "WATCHDOG: dumping blocked tasks"; echo w > /proc/sysrq-trigger ) &

# --nodiscard: these are image files, and discarding them buys nothing.
mkfs.btrfs -f --nodiscard -d $DPROF -m $MPROF $DEVS >/dev/null 2>&1 || { log "MKFS_FAILED"; }
mount -o rw /dev/ubda $MNT || { log "MOUNT_FAILED"; echo o > /proc/sysrq-trigger; sleep 60; }

# Automatic block-group reclaim: relocates a block group when its usage falls
# *below* RECLAIM percent, freeing the chunk.  Off by default on non-zoned
# filesystems (space_info->bg_reclaim_threshold stays 0), which is why it has
# to be set here to measure what it does to stranded space.
if [ -n "${RECLAIM:-}" ] && [ "${RECLAIM}" != "0" ]; then
	for f in /sys/fs/btrfs/*/allocation/data/bg_reclaim_threshold; do
		[ -f $f ] && { echo $RECLAIM > $f; log "reclaim threshold: $(cat $f)"; }
	done
fi
if [ -n "${PERIODIC:-}" ] && [ "${PERIODIC}" != "0" ]; then
	for f in /sys/fs/btrfs/*/allocation/data/periodic_reclaim; do
		[ -f $f ] && { echo 1 > $f; log "periodic reclaim: $(cat $f)"; }
	done
fi

python3 $(dirname $0)/age-workload.py $MNT/aged \
	--seed ${SEED:-1} --rounds ${ROUNDS:-12} --fill ${FILL:-0.75} 2>&1 |
	while read -r l; do log "$l"; done

sync
# What the reclaim machinery actually did: how many block groups it relocated
# and how many bytes that cost.
for d in /sys/fs/btrfs/*/allocation/data; do
	[ -d $d ] || continue
	log "reclaim: threshold=$(cat $d/bg_reclaim_threshold 2>/dev/null) periodic=$(cat $d/periodic_reclaim 2>/dev/null) count=$(cat $d/reclaim_count 2>/dev/null) bytes=$(cat $d/reclaim_bytes 2>/dev/null) errors=$(cat $d/reclaim_errors 2>/dev/null)"
done
dmesg | grep -ac "reclaiming chunk" | while read -r n; do log "dmesg reclaiming-chunk lines: $n"; done

# The write-intent log's own counters.  Its on-disk footprint is fixed, but
# its IO is not: a mark that adds a new region forces a 4KiB FUA write to
# every device, so the cost is O(devices) x (marks that change the block),
# and only a real workload says how often that is.
for f in /sys/fs/btrfs/*/raid56_write_intent; do
	[ -f $f ] && log "wib: $(tr '\n' ' ' < $f)"
done

# The aging workload is itself a large sample of sub-stripe writes: record
# what fraction of the writes had to touch committed data.
for f in /sys/fs/btrfs/*/raid56_write_profile; do
	[ -f $f ] && log "profile: $(tr '\n' ' ' < $f)"
done
btrfs filesystem df $MNT 2>&1 | while read -r l; do log "df: $l"; done
btrfs filesystem usage $MNT 2>&1 | grep -aE "Device size|Free|Data,|Used:" |
	while read -r l; do log "usage: $l"; done
umount $MNT && log "UMOUNT_OK" || log "UMOUNT_FAILED"
sync

# Dump the trees from in here: on a multi-device filesystem dump-tree needs
# every device registered, and the host has no btrfs module to scan with.
D=$T/umltest/$TAG
btrfs device scan >/dev/null 2>&1
btrfs inspect-internal dump-tree -t chunk  /dev/ubda > $D/chunk.txt 2>$D/chunk.err
btrfs inspect-internal dump-tree -t extent /dev/ubda > $D/extent.txt 2>$D/extent.err
log "chunk.txt $(wc -l < $D/chunk.txt) lines, extent.txt $(wc -l < $D/extent.txt) lines"
sync
dmesg | grep -aE "BUG:|WARNING:|KASAN|Oops" | head -3 | while read -r l; do log "splat: $l"; done
log "DONE"
echo o > /proc/sysrq-trigger
sleep 60
