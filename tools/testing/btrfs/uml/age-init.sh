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

mkfs.btrfs -f -d $DPROF -m $MPROF $DEVS >/dev/null 2>&1 || { log "MKFS_FAILED"; }
mount -o rw /dev/ubda $MNT || { log "MOUNT_FAILED"; echo o > /proc/sysrq-trigger; sleep 60; }

python3 $T/umltest/age-workload.py $MNT/aged \
	--seed ${SEED:-1} --rounds ${ROUNDS:-12} --fill ${FILL:-0.75} 2>&1 |
	while read -r l; do log "$l"; done

sync
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
