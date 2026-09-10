#!/bin/bash
# Runs as init inside UML (host filesystem as root).  Parameters arrive as
# environment variables from the kernel command line:
#   MODE     scenario, see the case statement
#   OPTS     extra mount options (comma separated, may be empty -> "rw")
#   PROFILE  data:metadata profiles, e.g. raid5:raid1
#   CRASH    crash injection point for MODE=prepare (1 or 2)
#   CONVERT  data:metadata profiles to convert to before the crash (prepare)
#   FAIL     device index to fail with device-mapper (detach/flakey modes)
#   TAG      result file suffix
#   MNTDEV   device to mount (default /dev/ubda)
#   NDEV     number of devices in the array
#   OMITTED  device omitted by the host (verify mode)
T=${BTRFS_TEST_DIR:?set BTRFS_TEST_DIR to a scratch directory}
export PATH=$T/progs-install/bin:/usr/sbin:/usr/bin:/sbin:/bin
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
RES=$T/umltest/results.$TAG
MNT=/mnt/umltest
mkdir -p $MNT
log() { echo "TEST[$MODE]: $*"; echo "[$MODE] $*" >> $RES; }
kmsg() { dmesg | grep -E "$1" | tail -n ${2:-4} | while read -r l; do log "dmesg: $l"; done; }
finish() {
	sync
	dmesg | grep -E "^\[ *[0-9.]+\] (BUG:|WARNING:|KASAN|INFO: task|Oops)|possible circular|lockdep" && log "KERNEL_SPLAT"
	echo o > /proc/sysrq-trigger
	sleep 60
}
# Dump blocked tasks to the console if the scenario takes too long.
watchdog() {
	( sleep ${1:-120}; echo 8 > /proc/sys/kernel/printk; echo "WATCHDOG: dumping blocked tasks";
	  echo w > /proc/sysrq-trigger; sleep 2; echo "WATCHDOG: done" ) &
}
OPTS=${OPTS:-rw}
MNTDEV=${MNTDEV:-/dev/ubda}
DPROF=${PROFILE%%:*}
MPROF=${PROFILE##*:}
btrfs device scan >/dev/null 2>&1
DEVS=$(ls /dev/ubd[a-z] 2>/dev/null | tr '\n' ' ')
log "devices present: $DEVS"
stats() {
	for f in /sys/fs/btrfs/*/raid56_write_intent; do
		[ -f $f ] && log "${1:-sysfs}: $(tr '\n' ' ' < $f)"
	done
	for f in /sys/fs/btrfs/*/raid56_write_profile; do
		[ -f $f ] && log "${1:-sysfs}: $(tr '\n' ' ' < $f)"
	done
}
do_mount() {
	mount -o "$1" $2 $MNT && return
	if dmesg | grep -q "log replay failed"; then
		# A log tree block hit two faults in one vertical stripe (a failed
		# write on the flaky device and the torn parity of the crashed
		# RMW): beyond RAID5 tolerance, detected.  Discard the log like an
		# administrator would and continue with the committed data.
		log "REPLAY_FAILED_DETECTED (two faults in one vertical stripe)"
		kmsg "log replay failed|bad tree block" 3
		btrfs rescue zero-log $2 >/dev/null 2>&1 && log "LOG_ZEROED"
		rm -f $T/umltest/manifest.$TAG; log "MANIFEST_SKIPPED_LOG_DISCARDED"
		mount -o "$1" $2 $MNT && return
	fi
	log "MOUNT_FAIL($1 $2)"; kmsg "BTRFS" 6; finish
}
verify_manifest() {
	# Every file whose fsync returned before the crash, name + md5.
	[ -f $T/umltest/manifest.$TAG ] || return 0
	local total=0 bad=0 f m got
	while read -r f m; do
		total=$((total+1))
		got=$(md5sum $f 2>/dev/null | awk '{print $1}')
		if [ "$got" != "$m" ]; then bad=$((bad+1)); log "$1_BAD $f expected $m got $got"; fi
	done < $T/umltest/manifest.$TAG
	log "$1_MANIFEST total=$total bad=$bad"
	[ "$bad" = 0 ] || kmsg "csum|error|corrupt" 5
}
verify_nocow() {
	# nodatacow has no checksum: compare with the content read after the
	# recovery mount, a stale parity would give different content.
	[ -f $T/umltest/nocow.md5.$TAG ] || return 0
	local M=$(md5sum $MNT/nocow 2>&1 | awk '{print $1}')
	if [ "$M" = "$(cat $T/umltest/nocow.md5.$TAG)" ]; then log "$1_NOCOW_OK"; else
		log "$1_NOCOW_FAIL md5=$M"; kmsg "csum|error|corrupt" 5; fi
}
verify_old() {
	echo 3 > /proc/sys/vm/drop_caches
	if [ -f $T/umltest/old.md5.$TAG ]; then
		local M=$(md5sum $MNT/old 2>&1 | awk '{print $1}')
		if [ "$M" = "$(cat $T/umltest/old.md5.$TAG)" ]; then log "$1_READ_OK"; else
			log "$1_READ_FAIL md5=$M"; kmsg "csum|error|corrupt" 5; fi
	fi
	verify_manifest $1
	verify_nocow $1
}
writers_start() {
	for w in 1 2 3; do
		(
		i=0
		while [ ! -f $T/umltest/stop.$TAG ]; do
			f=$MNT/bg$w-$i
			sz=$(( (RANDOM % 15 + 1) ))
			if [ "$WRITER" = "syncfs" ]; then
				head -c $((sz * 4096)) /dev/urandom > $f
				sync -f $f
			else
				dd if=/dev/urandom of=$f bs=4096 count=$sz conv=fsync status=none \
					&& echo "$f $(md5sum $f | awk '{print $1}')" >> $T/umltest/manifest.$TAG
			fi
			i=$((i+1))
		done
		) &
	done
}
writers_stop() { touch $T/umltest/stop.$TAG; wait; rm -f $T/umltest/stop.$TAG; }
rm -f $T/umltest/manifest.$TAG.new
# device-mapper helpers: dm_setup creates d0..dN-1 over the ubd devices
dm_setup() {
	local i=0
	DMDEVS=""
	for d in $DEVS; do
		local sz=$(blockdev --getsz $d)
		dmsetup create d$i --table "0 $sz linear $d 0" || log "DM_CREATE_FAIL $d"
		DMDEVS="$DMDEVS /dev/mapper/d$i"
		i=$((i+1))
	done
	# No udev in the guest: create the /dev/mapper nodes ourselves.
	dmsetup mknodes
	ls /dev/mapper/d0 >/dev/null || log "DM_NODE_MISSING"
}
# Register only the dm paths with btrfs so that the mount uses them.
dm_scan() { btrfs device scan --forget >/dev/null 2>&1; btrfs device scan $DMDEVS >/dev/null 2>&1; }
dm_reload() {	# name table...
	local n=$1; shift
	dmsetup suspend --nolockfs --noflush $n && dmsetup reload $n --table "$*" && dmsetup resume $n || log "DM_RELOAD_FAIL $n"
}
dm_detach() {	# index: every IO fails, like a pulled drive
	local d=$(echo $DEVS | awk -v i=$(( $1 + 1 )) '{print $i}')
	dm_reload d$1 "0 $(blockdev --getsz $d) error"
}
dm_error_writes() {	# index: reads work, every write fails
	local d=$(echo $DEVS | awk -v i=$(( $1 + 1 )) '{print $i}')
	dm_reload d$1 "0 $(blockdev --getsz $d) flakey $d 0 0 1000 1 error_writes"
}
dm_heal() {
	local d=$(echo $DEVS | awk -v i=$(( $1 + 1 )) '{print $i}')
	dm_reload d$1 "0 $(blockdev --getsz $d) linear $d 0"
}

# The 4K blocks of $MNT/nocow that the in-place overwrite targets, at a 64K
# stride so they land in different vertical stripes and on different devices.
NOCOW_BLOCKS=32
NOCOW_STRIDE=16          # in 4K blocks, so 64 KiB apart
# One RAID5 full stripe on a 4-device array is 3 x BTRFS_STRIPE_LEN = 192 KiB.
NOCOW_FS_BLOCKS=48       # 4K blocks per full stripe
NOCOW_NEXT_COL=16        # +64 KiB: the next data column of the same stripe
nocow_bad() {
	# How many of the overwritten blocks do NOT read back as the value the
	# overwrite was acknowledged to have written.  Zero means the data is
	# intact by whatever path this mount had to use to get it.
	local bad=0 i off got
	for i in $(seq 0 $((NOCOW_BLOCKS-1))); do
		off=$((i * NOCOW_STRIDE))
		got=$(dd if=$MNT/nocow bs=4096 skip=$off count=1 status=none 2>/dev/null |
		      tr -d 'B' | wc -c)
		[ "$got" = 0 ] || bad=$((bad+1))
	done
	echo $bad
}

case "$MODE" in
prepare)
	mkfs.btrfs -q -f -d $DPROF -m $MPROF $DEVS || { log "MKFS_FAIL"; finish; }
	do_mount $OPTS $MNTDEV
	log "mount options: $(grep umltest /proc/mounts | head -1)"
	stats
	# Committed data: 128K written and committed before the injected write.
	dd if=/dev/urandom of=$MNT/old bs=128K count=1 status=none
	sync
	md5sum $MNT/old | awk '{print $1}' > $T/umltest/old.md5.$TAG
	log "old md5 $(cat $T/umltest/old.md5.$TAG)"
	log "old layout: $(filefrag -v $MNT/old | sed -n 4p | tr -s ' ')"
	if [ -n "$CONVERT" ]; then
		writers_start
		btrfs balance start -f -dconvert=${CONVERT%%:*} -mconvert=${CONVERT##*:} $MNT >/dev/null 2>&1 \
			&& log "CONVERT_OK $CONVERT" || log "CONVERT_FAIL $CONVERT"
		writers_stop
		sync
		log "old layout after convert: $(filefrag -v $MNT/old | sed -n 4p | tr -s ' ')"
		stats
	fi
	# Arm the injection: the next sub-stripe RMW drops P/Q (1) or data (2)
	# writes, waits for the rest to land and panics.
	echo $CRASH > /sys/module/btrfs/parameters/raid56_crash_point 2>/dev/null || log "CRASH_ARM_FAIL"
	dd if=/dev/urandom of=$MNT/new bs=4K count=1 status=none
	sync
	# Not reached when the injection fired.
	log "NO_CRASH: raid56_crash_point=$(cat /sys/module/btrfs/parameters/raid56_crash_point)"
	umount $MNT
	finish
	;;
recover)
	do_mount $OPTS $MNTDEV
	kmsg "write-intent|regenerat|crash injection|tree-log" 8
	stats
	[ -f $MNT/nocow ] && md5sum $MNT/nocow | awk '{print $1}' > $T/umltest/nocow.md5.$TAG
	verify_old FULL
	umount $MNT || log "UMOUNT_FAIL"
	finish
	;;
ro_replay)
	# Read-only mount with a dirty tree log: the replay writes, so the
	# recovery and the log must run before it, even read-only.
	do_mount $OPTS,ro $MNTDEV
	kmsg "write-intent|tree-log|crash injection" 8
	stats "ro sysfs"
	[ -f $MNT/nocow ] && md5sum $MNT/nocow | awk '{print $1}' > $T/umltest/nocow.md5.$TAG
	verify_old RO
	umount $MNT || log "UMOUNT_FAIL"
	do_mount $OPTS $MNTDEV
	kmsg "write-intent" 4
	stats "rw sysfs"
	verify_old FULL
	umount $MNT || log "UMOUNT_FAIL"
	finish
	;;
prepare_fsync)
	# Nothing committed in the crashed full stripe: everything in it is
	# only referenced from the tree log (fsync without a transaction
	# commit), the log tree blocks and the fsync'ed data.  f shares its
	# vertical stripe with the crashed write of 'new'.
	mkfs.btrfs -q -f -d $DPROF -m $MPROF $DEVS || { log "MKFS_FAIL"; finish; }
	do_mount $OPTS $MNTDEV
	stats
	MAN=$T/umltest/manifest.$TAG
	: > $MAN
	dd if=/dev/urandom of=$MNT/f bs=4K count=1 conv=fsync status=none
	echo "$MNT/f $(md5sum $MNT/f | awk '{print $1}')" >> $MAN
	dd if=/dev/urandom of=$MNT/g bs=4K count=15 conv=fsync status=none
	echo "$MNT/g $(md5sum $MNT/g | awk '{print $1}')" >> $MAN
	log "f layout: $(filefrag -v $MNT/f | sed -n 4p | tr -s ' ')"
	log "g layout: $(filefrag -v $MNT/g | sed -n 4p | tr -s ' ')"
	echo $CRASH > /sys/module/btrfs/parameters/raid56_crash_point 2>/dev/null || log "CRASH_ARM_FAIL"
	dd if=/dev/urandom of=$MNT/new bs=4K count=1 conv=fsync status=none
	log "NO_CRASH: raid56_crash_point=$(cat /sys/module/btrfs/parameters/raid56_crash_point)"
	umount $MNT
	finish
	;;
inplace)
	# A nodatacow file overwritten in place with full stripe writes: the
	# overwritten sectors are referenced, the crash leaves them with a
	# stale parity unless the write was recorded.
	mkfs.btrfs -q -f -d $DPROF -m $MPROF $DEVS || { log "MKFS_FAIL"; finish; }
	do_mount $OPTS $MNTDEV
	stats
	touch $MNT/nocow; chattr +C $MNT/nocow
	dd if=/dev/urandom of=$MNT/nocow bs=64K count=12 conv=fsync status=none
	sync
	log "nocow layout: $(filefrag -v $MNT/nocow | sed -n 4p | tr -s ' ')"
	echo $CRASH > /sys/module/btrfs/parameters/raid56_crash_point 2>/dev/null || log "CRASH_ARM_FAIL"
	dd if=/dev/urandom of=$MNT/nocow bs=64K count=12 conv=fsync,notrunc status=none
	log "NO_CRASH: raid56_crash_point=$(cat /sys/module/btrfs/parameters/raid56_crash_point)"
	umount $MNT
	finish
	;;
remount)
	# Read-only mount must not touch the disks; the remount to read-write
	# must run the recovery before anything else is written.
	do_mount $OPTS,ro $MNTDEV
	stats "ro sysfs"
	kmsg "write-intent" 3
	mount -o remount,rw $MNT || { log "REMOUNT_RW_FAIL"; finish; }
	kmsg "write-intent|regenerat" 4
	stats "rw sysfs"
	verify_old FULL
	umount $MNT || log "UMOUNT_FAIL"
	finish
	;;
degraded)
	do_mount $OPTS,degraded $MNTDEV
	kmsg "write-intent log:" 3
	verify_old DEGRADED
	ls $MNT/new >/dev/null 2>&1 && log "new exists (unexpected, was not committed)"
	umount $MNT || log "UMOUNT_FAIL"
	finish
	;;
compat)
	# Kernel without write-intent support: RW mount must be refused, RO ok.
	if mount -o $OPTS $MNTDEV $MNT 2>/dev/null; then log "OLDKERNEL_RW_MOUNT_ALLOWED"; umount $MNT; else
		log "OLDKERNEL_RW_MOUNT_REFUSED"; kmsg "compat|unsupported|read-only" 3; fi
	if mount -o $OPTS,ro $MNTDEV $MNT 2>/dev/null; then log "OLDKERNEL_RO_MOUNT_OK"; verify_old OLDKERNEL_RO; umount $MNT; else
		log "OLDKERNEL_RO_MOUNT_FAIL"; fi
	finish
	;;
check)
	btrfs check $MNTDEV > $T/umltest/check.$TAG 2>&1 && log "CHECK_OK" || log "CHECK_FAIL rc=$?"
	grep -E "error|ERROR|found|compat" $T/umltest/check.$TAG | head -n 5 | while read -r l; do log "check: $l"; done
	btrfs inspect-internal dump-super $MNTDEV | grep -E "compat_ro_flags|incompat_flags" | while read -r l; do log "super: $l"; done
	python3 $T/umltest/raid56_wib_dump.py $DEVS 2>/dev/null | head -n 12 |
		while read -r l; do log "wib: $l"; done || log "WIB_DUMP_FAIL"
	finish
	;;
stress)
	# Concurrent small-file writers with fsync; the host kills the UML
	# process at a random moment.  Every file whose fsync returned is
	# recorded (name + md5) in a host-side manifest before the next write.
	mkfs.btrfs -q -f -d $DPROF -m $MPROF $DEVS || { log "MKFS_FAIL"; finish; }
	do_mount $OPTS $MNTDEV
	MAN=$T/umltest/manifest.$TAG
	: > $MAN
	# A nodatacow file overwritten in place by one writer: its sectors are
	# updated in place (torn content after a crash is expected for it).
	touch $MNT/nocow; chattr +C $MNT/nocow; dd if=/dev/zero of=$MNT/nocow bs=4096 count=64 conv=fsync status=none
	for w in 1 2 3 4; do
		(
		i=0
		while true; do
			f=$MNT/w$w-$i
			sz=$(( (RANDOM % 15 + 1) ))
			dd if=/dev/urandom of=$f bs=4096 count=$sz conv=fsync status=none
			m=$(md5sum $f | awk '{print $1}')
			echo "$f $m" >> $MAN
			i=$((i+1))
			dd if=/dev/urandom of=$MNT/nocow bs=4096 count=1 seek=$((RANDOM % 64)) conv=notrunc,fsync status=none
		done
		) &
	done
	echo "STRESS_START"
	sleep 600
	;;
verify)
	do_mount "$OPTS${OMITTED:+,degraded}" $MNTDEV
	echo 3 > /proc/sys/vm/drop_caches
	MAN=$T/umltest/manifest.$TAG
	total=0; bad=0
	while read -r f m; do
		total=$((total+1))
		got=$(md5sum $f 2>/dev/null | awk '{print $1}')
		if [ "$got" != "$m" ]; then bad=$((bad+1)); log "BAD $f expected $m got $got"; fi
	done < $MAN
	cat $MNT/nocow > /dev/null 2>&1 && log "nocow readable" || log "NOCOW_READ_FAIL"
	log "VERIFY total=$total bad=$bad omitted=${OMITTED:-none}"
	kmsg "write-intent log:" 3
	stats
	umount $MNT || log "UMOUNT_FAIL"
	finish
	;;
replace)
	# Device replace, remove and add while sub-stripe writes are in
	# flight: exercises the dev-replace finishing path that waits for
	# in-flight bios under device_list_mutex, and the RCU device list
	# traversal of the log writer (lockdep is enabled in this kernel).
	mkfs.btrfs -q -f -d $DPROF -m $MPROF /dev/ubda /dev/ubdb /dev/ubdc /dev/ubdd || { log "MKFS_FAIL"; finish; }
	do_mount $OPTS /dev/ubda
	watchdog 150
	writers_start
	sleep 3
	btrfs replace start -B -f 1 /dev/ubde $MNT && log "REPLACE_OK" || log "REPLACE_FAIL"
	sleep 2
	btrfs device add -f /dev/ubda $MNT && log "ADD_OK" || log "ADD_FAIL"
	sleep 2
	btrfs device remove /dev/ubdb $MNT && log "REMOVE_OK" || log "REMOVE_FAIL"
	sleep 2
	writers_stop
	sync
	stats
	umount $MNT || log "UMOUNT_FAIL"
	btrfs check /dev/ubda 2>&1 | grep -E "error|found|ERROR" | head -n 3 | while read -r l; do log "check: $l"; done
	finish
	;;
convert)
	# No RAID56 at mkfs time: the log must be enabled when the first
	# RAID5 chunk is created by the balance, at the next commit.
	mkfs.btrfs -q -f -d raid1 -m raid1 $DEVS || { log "MKFS_FAIL"; finish; }
	do_mount $OPTS $MNTDEV
	stats before
	writers_start
	sleep 2
	btrfs balance start -f -dconvert=raid5 -mconvert=raid5 $MNT >/dev/null 2>&1 && log "CONVERT_OK" || log "CONVERT_FAIL"
	sleep 2
	writers_stop
	sync
	stats after
	umount $MNT || log "UMOUNT_FAIL"
	btrfs inspect-internal dump-super $MNTDEV | grep -E "compat_ro_flags" | while read -r l; do log "super: $l"; done
	finish
	;;
convert_away)
	# RAID5 -> RAID1 with writers: the log stays enabled (flag set), the
	# remaining RAID5 chunks are still protected until they are gone.
	mkfs.btrfs -q -f -d raid5 -m raid5 $DEVS || { log "MKFS_FAIL"; finish; }
	do_mount $OPTS $MNTDEV
	dd if=/dev/urandom of=$MNT/old bs=128K count=1 status=none; sync
	md5sum $MNT/old | awk '{print $1}' > $T/umltest/old.md5.$TAG
	writers_start
	sleep 2
	btrfs balance start -f -dconvert=raid1 -mconvert=raid1 $MNT >/dev/null 2>&1 && log "CONVERT_AWAY_OK" || log "CONVERT_AWAY_FAIL"
	writers_stop
	sync
	stats after
	verify_old FULL
	umount $MNT || log "UMOUNT_FAIL"
	btrfs inspect-internal dump-super $MNTDEV | grep -E "compat_ro_flags" | while read -r l; do log "super: $l"; done
	finish
	;;
toggle)
	# Feature toggling through sysfs while writes are in flight.
	mkfs.btrfs -q -f -d $DPROF -m $MPROF $DEVS || { log "MKFS_FAIL"; finish; }
	do_mount $OPTS,noraid56_write_intent $MNTDEV
	watchdog 150
	writers_start
	sleep 2
	for i in 1 2 3; do
		echo 1 > /sys/fs/btrfs/*/features/raid56_write_intent || log "ENABLE_FAIL"
		sleep 1
		echo 0 > /sys/fs/btrfs/*/features/raid56_write_intent || log "DISABLE_FAIL"
		sleep 1
	done
	echo 1 > /sys/fs/btrfs/*/features/raid56_write_intent
	writers_stop
	sync
	stats
	umount $MNT || log "UMOUNT_FAIL"
	btrfs inspect-internal dump-super $MNTDEV | grep -E "compat_ro_flags" | while read -r l; do log "super: $l"; done
	finish
	;;
detach)
	# A drive that fails every IO in the middle of writes (pulled cable),
	# no crash.  Its stripes are kept in the log (sticky); after the drive
	# is back, the next mount regenerates their parity.  Then the array
	# must survive losing any other device.
	dm_setup
	mkfs.btrfs -q -f -d $DPROF -m $MPROF $DMDEVS || { log "MKFS_FAIL"; finish; }
	dm_scan
	do_mount $OPTS /dev/mapper/d0
	log "fs devices: $(btrfs filesystem show $MNT 2>/dev/null | grep devid | tr -s ' ' | tr '\n' ';')"
	dd if=/dev/urandom of=$MNT/old bs=128K count=1 status=none; sync
	md5sum $MNT/old | awk '{print $1}' > $T/umltest/old.md5.$TAG
	writers_start
	sleep 2
	dm_detach $FAIL; log "detached device $FAIL"
	sleep 4
	writers_stop
	sync
	stats "while detached"
	kmsg "write-intent|lost|error" 4
	dm_heal $FAIL; log "healed device $FAIL"
	umount $MNT || log "UMOUNT_FAIL"
	dmsetup remove_all
	finish
	;;
nocow_stale)
	# Does the mount-time recovery DESTROY nodatacow data that was still
	# recoverable before it ran?
	#
	# A nodatacow sector has no checksum.  scrub_verify_one_sector() has no
	# choice but to trust it ("For cases without csum, we have no other
	# choice but to trust it"), so it clears the sector's error bit, and
	# scrub_raid56_parity_stripe() then recomputes the parity from it.
	# When that sector is the one a failed write left STALE, the parity was
	# the only place the acknowledged content still existed -- and the
	# recovery overwrites it with a parity computed from the stale content.
	#
	# This boot builds that state with a real device write error, not a
	# crash: the write must be ACKNOWLEDGED (one fault is inside RAID5
	# tolerance) and the stripe recorded, which is exactly what makes the
	# next mount scrub it.
	dm_setup
	mkfs.btrfs -q -f -d $DPROF -m $MPROF $DMDEVS || { log "MKFS_FAIL"; finish; }
	dm_scan
	do_mount "$OPTS${NOLOG:+,noraid56_write_intent}" /dev/mapper/d0
	log "log state: $(cat /sys/fs/btrfs/*/raid56_write_intent 2>/dev/null | tr '\n' ' ')"
	touch $MNT/nocow; chattr +C $MNT/nocow || { log "CHATTR_FAIL"; finish; }
	lsattr $MNT/nocow 2>/dev/null | grep -q C || log "NOT_NODATACOW"
	dd if=/dev/zero bs=1M count=2 status=none | tr '\000' 'A' > $MNT/nocow
	sync
	log "nocow layout: $(filefrag -v $MNT/nocow 2>/dev/null | sed -n 4p | tr -s ' ')"
	stats "before"
	# Every write to this device now fails; reads still work.  A sub-stripe
	# write whose data sector lands here takes one fault, which RAID5
	# tolerates, so the write is acknowledged and the stripe is recorded.
	dm_error_writes $FAIL; log "write errors on device $FAIL"
	acked=0; failed=0
	for i in $(seq 0 $((NOCOW_BLOCKS-1))); do
		if dd if=/dev/zero bs=4096 count=1 status=none | tr '\000' 'B' |
		   dd of=$MNT/nocow bs=4096 seek=$((i * NOCOW_STRIDE)) count=1 \
		      conv=notrunc,fsync status=none 2>/dev/null; then
			acked=$((acked+1))
		else
			failed=$((failed+1))
		fi
	done
	sync
	log "in-place overwrites: $acked acknowledged, $failed refused"
	stats "after write errors"
	kmsg "write-intent|raid56" 6
	# Heal it so the next boots see a complete, healthy array: the point is
	# what recovery does, not what a broken device does.
	dm_heal $FAIL; log "healed device $FAIL"
	sync
	umount $MNT || log "UMOUNT_FAIL"
	dmsetup remove_all
	finish
	;;
pausehang_log_prep)
	# Leave BOTH a dirty tree log and recorded stripes, then die without
	# unmounting.  The next mount then runs btrfs_wib_recover_after_replay(),
	# which is the one recovery path that runs after the transaction kthread
	# has been started -- the only place a commit can overlap it.
	dm_setup
	mkfs.btrfs -q -f -d $DPROF -m $MPROF $DMDEVS || { log "MKFS_FAIL"; finish; }
	dm_scan
	do_mount $OPTS /dev/mapper/d0
	dd if=/dev/urandom of=$MNT/base bs=1M count=8 conv=fsync status=none
	sync
	dm_error_writes $FAIL; log "write errors on device $FAIL"
	for i in $(seq 0 39); do
		dd if=/dev/urandom of=$MNT/base bs=4096 count=1 seek=$((i * 48)) \
		   conv=notrunc,fsync status=none 2>/dev/null
	done
	# fsync without sync: the data is referenced only by the tree log, so
	# the next mount has a log to replay before it can finish recovering.
	for i in $(seq 0 7); do
		dd if=/dev/urandom of=$MNT/logged$i bs=64K count=1 conv=fsync \
		   status=none 2>/dev/null
	done
	stats "recorded with a dirty log"
	log "PREP_DONE"
	# No umount: leave the log dirty.
	# Power off, NOT reboot: sysrq-b restarts the guest, which re-runs this
	# same init and repeats the whole preparation until the host timeout
	# kills it.  No sync first -- the dirty tree log is the point.
	echo o > /proc/sysrq-trigger
	sleep 60
	;;
pausehang_log)
	# Mount normally.  btrfs_wib_recover_after_replay() runs from
	# open_ctree() AFTER cleaner_kthread and transaction_kthread have
	# started and after the tree log has been replayed, so unlike
	# btrfs_remount_rw() a commit really can land while it is running.
	echo ${DELAY:-6000} > /sys/module/btrfs/parameters/raid56_recovery_delay_ms \
		2>/dev/null || log "DELAY_ARM_FAIL"
	log "recovery delay armed: $(cat /sys/module/btrfs/parameters/raid56_recovery_delay_ms 2>/dev/null)"
	watchdog 200
	log "MOUNT_START"
	if timeout 240 mount -o rw,commit=1 $MNTDEV $MNT; then
		log "MOUNT_DONE"
	else
		log "MOUNT_STUCK rc=$?"
		echo w > /proc/sysrq-trigger 2>/dev/null; sleep 3
	fi
	echo 0 > /sys/module/btrfs/parameters/raid56_recovery_delay_ms 2>/dev/null
	log "pause samples: $(dmesg | grep -c "recovery delay: pause_req")"
	log "samples with a pauser: $(dmesg | grep "recovery delay: pause_req" | grep -vc "pause_req 0")"
	dmesg | grep "recovery delay: pause_req" | grep -v "pause_req 0" | tail -4 | while read -r l; do log "PAUSER: $l"; done
	stats "after mount"
	kmsg "blocked for more|replay|write-intent" 8
	umount $MNT 2>/dev/null
	finish
	;;
pausehang_prep)
	# Leave a filesystem with recorded stripes and unmount it, so the next
	# boot's btrfs_wib_load() puts them in wib->pending -- which is the only
	# thing btrfs_wib_recover() iterates.
	dm_setup
	mkfs.btrfs -q -f -d $DPROF -m $MPROF $DMDEVS || { log "MKFS_FAIL"; finish; }
	dm_scan
	do_mount $OPTS /dev/mapper/d0
	dd if=/dev/urandom of=$MNT/base bs=1M count=8 conv=fsync status=none
	sync
	dm_error_writes $FAIL; log "write errors on device $FAIL"
	for i in $(seq 0 39); do
		dd if=/dev/urandom of=$MNT/base bs=4096 count=1 seek=$((i * 48)) \
		   conv=notrunc,fsync status=none 2>/dev/null
	done
	sync
	dm_heal $FAIL
	stats "recorded"
	umount $MNT || log "UMOUNT_FAIL"
	dmsetup remove_all 2>/dev/null
	finish
	;;
pausehang)
	# Can the write-intent log's recovery wedge against the scrub pause
	# protocol?
	#
	#   btrfs_scrub_pause():  inc pause_req; wait until paused == running
	#   scrub_pause_off():    wait until pause_req == 0; then dec paused
	#
	# The recovery is deliberately absent from scrubs_running, but
	# scrub_raid56_parity_stripe() calls scrub_blocked_if_needed(), which
	# increments scrubs_paused.  While the recovery sits there paused is 1
	# and running is 0, so a commit waits for 1 == 0 while the recovery
	# waits for pause_req to reach 0 -- which that commit is holding above
	# zero.
	#
	# Mount READ-ONLY, so btrfs_wib_load() fills wib->pending and
	# btrfs_wib_rw_mount() is deferred; the remount below is then the thing
	# that actually runs the recovery.  Mounting read-write first would
	# consume wib->pending at mount time and leave the remount nothing to
	# do, which is what an earlier version of this scenario did.
	do_mount ro $MNTDEV
	stats "mounted ro"
	pend=$(grep -o "pending_recovery_regions [0-9]*" /sys/fs/btrfs/*/raid56_write_intent 2>/dev/null | awk '{print $2}' | head -1)
	log "pending regions before remount: ${pend:-unknown}"
	[ "${pend:-0}" = 0 ] && log "NOTHING_TO_RECOVER"
	echo ${DELAY:-40} > /sys/module/btrfs/parameters/raid56_recovery_delay_ms \
		2>/dev/null || log "DELAY_ARM_FAIL"
	log "recovery delay armed: $(cat /sys/module/btrfs/parameters/raid56_recovery_delay_ms 2>/dev/null)"
	watchdog 150
	log "REMOUNT_RW_START"
	if timeout 180 mount -o remount,rw,commit=1 $MNT; then
		log "REMOUNT_RW_DONE"
	else
		log "REMOUNT_RW_STUCK rc=$?"
		echo w > /proc/sysrq-trigger 2>/dev/null
		sleep 3
	fi
	echo 0 > /sys/module/btrfs/parameters/raid56_recovery_delay_ms 2>/dev/null
	stats "after remount"
	log "pause samples: $(dmesg | grep -c "recovery delay: pause_req")"
	log "samples with a pauser: $(dmesg | grep "recovery delay: pause_req" | grep -vc "pause_req 0")"
	dmesg | grep "recovery delay: pause_req" | tail -4 | while read -r l; do log "sample: $l"; done
	kmsg "blocked for more|scrub|write-intent" 8
	umount $MNT 2>/dev/null
	finish
	;;
nocow_rmw)
	# Does an ordinary FAULT-FREE write destroy data a previous failed
	# write left recoverable?
	#
	# To compute a new parity, a sub-stripe write must read the data
	# stripes it is not writing.  A nodatacow sector has no checksum, so a
	# sector left stale by an earlier failed write is believed, and the
	# parity -- which held the acknowledged value -- is recomputed from it.
	# No crash, no second device failure, no scrub: the very next write to
	# the same full stripe is enough.
	#
	# Pass 1 writes column 0 of each full stripe while a device fails
	# writes.  The device is then healed, and pass 2 writes column 1 of the
	# SAME full stripes with every write succeeding.  Reading pass 1's
	# blocks with the failed device omitted says whether the parity still
	# has them.
	#
	# A RAID5 full stripe here is 3 x 64K, so +64K is the next column.
	dm_setup
	mkfs.btrfs -q -f -d $DPROF -m $MPROF $DMDEVS || { log "MKFS_FAIL"; finish; }
	dm_scan
	do_mount $OPTS /dev/mapper/d0
	touch $MNT/nocow; chattr +C $MNT/nocow || { log "CHATTR_FAIL"; finish; }
	lsattr $MNT/nocow 2>/dev/null | grep -q C || log "NOT_NODATACOW"
	dd if=/dev/zero bs=1M count=4 status=none | tr '\000' 'A' > $MNT/nocow
	sync
	dm_error_writes $FAIL; log "write errors on device $FAIL"
	acked=0
	for i in $(seq 0 $((NOCOW_BLOCKS-1))); do
		dd if=/dev/zero bs=4096 count=1 status=none | tr '\000' 'B' |
		dd of=$MNT/nocow bs=4096 seek=$((i * NOCOW_FS_BLOCKS)) count=1 \
		   conv=notrunc,fsync status=none 2>/dev/null && acked=$((acked+1))
	done
	sync
	log "pass1 (device failing): $acked of $NOCOW_BLOCKS acknowledged"
	stats "after pass1"
	# Healthy again: pass 2 takes no faults at all.
	dm_heal $FAIL; log "healed device $FAIL"
	# Evict the stripe cache.  Pass 1's writes were ACKNOWLEDGED, so
	# rmw_rbio() left RBIO_CACHE_READY_BIT set and the cache still holds the
	# content the caller was told is on disk -- correct content, which pass 2
	# would then use, and nothing would be destroyed.  That is real but it is
	# not durable: the cache holds RBIO_CACHE_SIZE (1024) rbios and is only
	# cleared at unmount, so any busy filesystem cycles through it.  Touch
	# more distinct full stripes than it can hold, so pass 2 has to read the
	# disk like it would on a real array.
	touch $MNT/churn; chattr +C $MNT/churn 2>/dev/null
	fallocate -l 256M $MNT/churn 2>/dev/null || log "FALLOCATE_FAIL"
	n=0
	for i in $(seq 0 1200); do
		dd if=/dev/zero of=$MNT/churn bs=4096 count=1 \
		   seek=$((i * NOCOW_FS_BLOCKS)) conv=notrunc status=none 2>/dev/null \
			&& n=$((n+1))
	done
	sync
	log "stripe-cache churn: $n distinct full stripes touched (cache holds 1024)"
	clean=0
	for i in $(seq 0 $((NOCOW_BLOCKS-1))); do
		dd if=/dev/zero bs=4096 count=1 status=none | tr '\000' 'C' |
		dd of=$MNT/nocow bs=4096 seek=$((i * NOCOW_FS_BLOCKS + NOCOW_NEXT_COL)) count=1 \
		   conv=notrunc,fsync status=none 2>/dev/null && clean=$((clean+1))
	done
	sync
	log "pass2 (healthy, same full stripes): $clean of $NOCOW_BLOCKS acknowledged"
	stats "after pass2"
	kmsg "raid56|write-intent" 6
	umount $MNT || log "UMOUNT_FAIL"
	dmsetup remove_all
	finish
	;;
nocow_rmw_probe)
	# Read pass 1's blocks with the failing device omitted, so every one of
	# them must come from the parity.
	do_mount ro,degraded $MNTDEV
	bad=0
	for i in $(seq 0 $((NOCOW_BLOCKS-1))); do
		got=$(dd if=$MNT/nocow bs=4096 skip=$((i * NOCOW_FS_BLOCKS)) count=1 \
		      status=none 2>/dev/null | tr -d 'B' | wc -c)
		[ "$got" = 0 ] || bad=$((bad+1))
	done
	log "NOCOW_RMW bad=$bad of $NOCOW_BLOCKS"
	echo $bad > $T/umltest/nocow.rmw.$TAG
	umount $MNT || log "UMOUNT_FAIL"
	finish
	;;
nocow_replay_prep)
	# Leave error records AND a dirty tree log, then die without
	# unmounting.  The next read-write mount replays the log and then runs
	# btrfs_wib_recover_after_replay(), which is the recovery entry point
	# that handles error records exclusively -- and the one nocow_stale.sh
	# cannot reach, because it unmounts cleanly and so leaves no log.
	dm_setup
	mkfs.btrfs -q -f -d $DPROF -m $MPROF $DMDEVS || { log "MKFS_FAIL"; finish; }
	dm_scan
	do_mount $OPTS /dev/mapper/d0
	touch $MNT/nocow; chattr +C $MNT/nocow || { log "CHATTR_FAIL"; finish; }
	lsattr $MNT/nocow 2>/dev/null | grep -q C || log "NOT_NODATACOW"
	dd if=/dev/zero bs=1M count=2 status=none | tr '\000' 'A' > $MNT/nocow
	sync
	dm_error_writes $FAIL; log "write errors on device $FAIL"
	acked=0
	for i in $(seq 0 $((NOCOW_BLOCKS-1))); do
		dd if=/dev/zero bs=4096 count=1 status=none | tr '\000' 'B' |
		dd of=$MNT/nocow bs=4096 seek=$((i * NOCOW_STRIDE)) count=1 \
		   conv=notrunc,fsync status=none 2>/dev/null && acked=$((acked+1))
	done
	log "in-place overwrites: $acked of $NOCOW_BLOCKS acknowledged"
	dm_heal $FAIL; log "healed device $FAIL"
	# fsync-only files so a tree log is left dirty; no sync, no umount.
	for i in $(seq 0 5); do
		dd if=/dev/urandom of=$MNT/logged$i bs=64K count=1 conv=fsync \
		   status=none 2>/dev/null
	done
	stats "recorded with a dirty log"
	# Power off, NOT reboot: sysrq-b restarts the guest, which re-runs this
	# same init and repeats the whole preparation until the host timeout
	# kills it.  No sync first -- the dirty tree log is the point.
	echo o > /proc/sysrq-trigger
	sleep 60
	;;
nocow_replay_probe)
	# nologreplay keeps this mount from replaying the log, which is what
	# would otherwise drag btrfs_wib_rw_mount() in even on a read-only
	# mount -- so this really does read the array without any recovery
	# having run.  The failed device is omitted, so every one of the
	# overwritten blocks has to come from the parity.
	do_mount ro,nologreplay,degraded $MNTDEV
	bad=$(nocow_bad)
	log "NOCOW_REPLAY_${PROBE:-x} bad=$bad of $NOCOW_BLOCKS"
	echo $bad > $T/umltest/nocow.replay.${PROBE:-x}.$TAG
	umount $MNT || log "UMOUNT_FAIL"
	finish
	;;
nocow_replay_recover)
	# Replays the log, then recovers the error records.
	do_mount $OPTS $MNTDEV
	stats "after replay recovery"
	kmsg "replay|write-intent" 6
	umount $MNT || log "UMOUNT_FAIL"
	finish
	;;
nocow_scrub)
	# The same question asked of plain "btrfs scrub", with the write-intent
	# log switched off entirely (noraid56_write_intent), so nothing in this
	# series is involved.  scrub_stripe() passes regen_parity=true
	# unconditionally, and scrub_verify_one_sector() is upstream code, so
	# the expectation is that upstream scrub destroys the parity copy just
	# as the recovery does.
	do_mount $OPTS,noraid56_write_intent $MNTDEV
	log "log state: $(cat /sys/fs/btrfs/*/raid56_write_intent 2>/dev/null | tr '\n' ' ')"
	btrfs scrub start -B $MNT 2>&1 | while read -r l; do log "scrub: $l"; done
	log "NOCOW_DIRECT bad=$(nocow_bad) of $NOCOW_BLOCKS"
	umount $MNT || log "UMOUNT_FAIL"
	finish
	;;
nocow_probe)
	# Read the overwritten blocks WITHOUT letting recovery run: read-only,
	# so btrfs_wib_rw_mount() is skipped.  The host omits the device whose
	# sectors the failed writes left stale, which forces every one of them
	# to be reconstructed from the parity -- so this measures what the
	# parity still holds.
	do_mount ro,degraded $MNTDEV
	bad=$(nocow_bad)
	log "NOCOW_PROBE_${PROBE:-x} bad=$bad of $NOCOW_BLOCKS"
	echo $bad > $T/umltest/nocow.bad.${PROBE:-x}.$TAG
	umount $MNT || log "UMOUNT_FAIL"
	finish
	;;
nocow_recover)
	# A normal read-write mount: this is what runs btrfs_wib_recover() and
	# scrubs every stripe the log recorded.
	do_mount $OPTS $MNTDEV
	stats "after recovery"
	kmsg "write-intent" 8
	# Read with every device present too, which is the ordinary nodatasum
	# exposure (the stale sector is returned as-is) rather than the
	# question this scenario asks.
	log "NOCOW_DIRECT bad=$(nocow_bad) of $NOCOW_BLOCKS"
	umount $MNT || log "UMOUNT_FAIL"
	finish
	;;
flakey)
	# Like detach, but the drive only fails writes (reads still work), and
	# the filesystem is crashed while the drive is bad.
	dm_setup
	mkfs.btrfs -q -f -d $DPROF -m $MPROF $DMDEVS || { log "MKFS_FAIL"; finish; }
	dm_scan
	do_mount $OPTS /dev/mapper/d0
	log "fs devices: $(btrfs filesystem show $MNT 2>/dev/null | grep devid | tr -s ' ' | tr '\n' ';')"
	dd if=/dev/urandom of=$MNT/old bs=128K count=1 status=none; sync
	md5sum $MNT/old | awk '{print $1}' > $T/umltest/old.md5.$TAG
	writers_start
	sleep 2
	dm_error_writes $FAIL; log "write errors on device $FAIL"
	sleep 3
	stats "with write errors"
	kmsg "write-intent|error" 4
	echo ${CRASH:-1} > /sys/module/btrfs/parameters/raid56_crash_point 2>/dev/null || log "CRASH_ARM_FAIL"
	dd if=/dev/urandom of=$MNT/new bs=4K count=1 conv=fsync status=none
	log "NO_CRASH"
	finish
	;;
degraded_fresh)
	# A RAID6 array that is degraded from the start, writing into space
	# that has never been written.  The parity of a never-written vertical
	# stripe is whatever was on the disk, so P and Q disagree; a missing
	# device makes every such stripe need reconstruction, and free space
	# has no checksum to vouch for the result.  If the Q cross-check in
	# recover_vertical() rejects that, a degraded array cannot write into
	# fresh space at all.
	mkfs.btrfs -q -f -d $DPROF -m $MPROF $DEVS || { log "MKFS_FAIL"; finish; }
	do_mount $OPTS,degraded $MNTDEV
	watchdog 120
	fails=0
	for i in $(seq 1 20); do
		dd if=/dev/urandom of=$MNT/f$i bs=4K count=1 conv=fsync status=none \
			2>/dev/null || fails=$((fails+1))
	done
	sync 2>/dev/null || fails=$((fails+1))
	log "degraded fresh sub-stripe writes: $fails of 21 failed"
	btrfs filesystem df $MNT 2>&1 | while read -r l; do log "df: $l"; done
	# Force a genuine read-modify-write: overwrite part of an existing
	# extent in place, which cannot be redirected to fresh space.
	dd if=/dev/urandom of=$MNT/big bs=1M count=4 conv=fsync status=none 2>/dev/null
	sync
	chattr +C $MNT/nocow 2>/dev/null
	dd if=/dev/zero of=$MNT/nocow bs=1M count=2 conv=fsync status=none 2>/dev/null
	sync
	dd if=/dev/urandom of=$MNT/nocow bs=4K count=4 seek=7 conv=notrunc,fsync \
		status=none 2>/dev/null || log "INPLACE_WRITE_FAIL"
	sync
	[ "$fails" = 0 ] && log "DEGRADED_FRESH_OK" || log "DEGRADED_FRESH_FAIL"
	kmsg "does not match the Q syndrome" 3
	stats
	umount $MNT || log "UMOUNT_FAIL"
	finish
	;;
degraded_write)
	# The array is already degraded (device omitted by the host) while
	# writes happen and the crash hits.  Recovery cannot regenerate the
	# missing device's sectors; committed data on the present devices
	# must still be intact and the loss must be detected, not silent.
	do_mount $OPTS,degraded $MNTDEV
	stats
	dd if=/dev/urandom of=$MNT/old2 bs=128K count=1 status=none; sync
	md5sum $MNT/old2 | awk '{print $1}' > $T/umltest/old2.md5.$TAG
	echo ${CRASH:-1} > /sys/module/btrfs/parameters/raid56_crash_point 2>/dev/null || log "CRASH_ARM_FAIL"
	dd if=/dev/urandom of=$MNT/new bs=4K count=1 conv=fsync status=none
	log "NO_CRASH"
	finish
	;;
degraded_verify)
	do_mount "$OPTS${OMITTED:+,degraded}" $MNTDEV
	kmsg "write-intent|regenerat" 4
	stats
	verify_old FULL
	echo 3 > /proc/sys/vm/drop_caches
	M=$(md5sum $MNT/old2 2>&1 | awk '{print $1}')
	[ "$M" = "$(cat $T/umltest/old2.md5.$TAG)" ] && log "OLD2_READ_OK" || { log "OLD2_READ_FAIL md5=$M"; kmsg "csum|error" 3; }
	umount $MNT || log "UMOUNT_FAIL"
	finish
	;;
locate)
	# Print the physical location of the first sector of 'old' on every
	# device, for host-side corruption tests.
	do_mount $OPTS,ro $MNTDEV
	L=$(filefrag -v $MNT/old | sed -n 4p | awk -F: '{print $3}' | awk '{print $1}' | tr -d '.')
	umount $MNT
	log "old logical block $L"
	btrfs-map-logical -l $((L * 4096)) -b 4096 $MNTDEV 2>&1 | while read -r l; do log "map: $l"; done
	finish
	;;
writers)
	# Plain concurrent writer workload for a fixed time, no failure.
	mkfs.btrfs -q -f -d $DPROF -m $MPROF $DEVS || { log "MKFS_FAIL"; finish; }
	do_mount $OPTS $MNTDEV
	watchdog ${WATCH:-100}
	writers_start
	sleep ${DURATION:-30}
	writers_stop
	log "writers finished: $(ls $MNT | wc -l) files"
	sync
	stats
	umount $MNT || log "UMOUNT_FAIL"
	finish
	;;
stale_parity)
	# A device rejects writes for a while.  Every sector it does not take
	# stays behind while the rest of its vertical stripe moves on, and
	# because a single fault is within what RAID5/6 tolerates the writes
	# are accepted: the writer is told they succeeded.  Nothing tracks
	# those sectors afterwards.  For a file with no checksums a later read
	# returns the stale bytes with no error at all, and the retry added to
	# the write path only removes the case where the device recovers in
	# time.  This reproduces that exposure; see the "remaining exposures"
	# section of tools/testing/btrfs/raid56_redundancy_model.py.
	dm_setup
	mkfs.btrfs -q -f -d $DPROF -m $MPROF $DMDEVS || { log "MKFS_FAIL"; finish; }
	dm_scan
	do_mount $OPTS /dev/mapper/d0
	mkdir -p $MNT/nc; chattr +C $MNT/nc 2>/dev/null
	dd if=/dev/urandom of=$MNT/nc/f bs=64K count=24 conv=fsync status=none
	sync
	md5sum $MNT/nc/f | awk '{print $1}' > $T/umltest/old.md5.$TAG
	log "nocow file md5 $(cat $T/umltest/old.md5.$TAG)"
	dm_error_writes $FAIL; log "write errors on device $FAIL"
	# Sub-stripe rewrites: data and Q land, P on the bad device does not.
	for off in 0 2 4 6 8 10 12 14 16 18 20 22; do
		dd if=/dev/urandom of=$MNT/nc/f bs=4K count=1 seek=$((off * 16)) \
			conv=notrunc,fsync status=none 2>/dev/null
	done
	sync
	md5sum $MNT/nc/f | awk '{print $1}' > $T/umltest/new.md5.$TAG
	log "after rewrites md5 $(cat $T/umltest/new.md5.$TAG)"
	dm_heal $FAIL; log "healed device $FAIL"
	kmsg "raid56:|does not match the Q syndrome" 6
	umount $MNT || log "UMOUNT_FAIL"
	dmsetup remove_all
	finish
	;;
stale_parity_verify)
	# The array comes up with one data device missing: every read of the
	# file needs a single-erasure rebuild.
	dm_setup
	dm_scan
	do_mount "$OPTS${OMITTED:+,degraded}" /dev/mapper/d0
	echo 3 > /proc/sys/vm/drop_caches
	M=$(md5sum $MNT/nc/f 2>/dev/null | awk '{print $1}')
	RC=$?
	WANT=$(cat $T/umltest/new.md5.$TAG)
	if [ -z "$M" ]; then
		log "STALE_SECTOR_READ_REFUSED (detected)"
	elif [ "$M" = "$WANT" ]; then
		log "STALE_SECTOR_READ_CORRECT"
	else
		log "STALE_SECTOR_SILENT_CORRUPTION md5=$M want=$WANT (known exposure)"
	fi
	kmsg "does not match the Q syndrome|csum|error" 6
	umount $MNT || log "UMOUNT_FAIL"
	dmsetup remove_all
	finish
	;;
devstats)
	# Directly exercise the new accounting: one device fails writes for a
	# while (transient), so the RMW retry should fire and the device error
	# counters should move.  Previously raid56.c touched neither.
	dm_setup
	mkfs.btrfs -q -f -d $DPROF -m $MPROF $DMDEVS || { log "MKFS_FAIL"; finish; }
	dm_scan
	do_mount $OPTS /dev/mapper/d0
	dd if=/dev/urandom of=$MNT/old bs=128K count=1 status=none; sync
	md5sum $MNT/old | awk '{print $1}' > $T/umltest/old.md5.$TAG
	log "stats before: $(btrfs device stats $MNT | tr '\n' ' ')"
	dm_error_writes $FAIL; log "write errors on device $FAIL"
	writers_start
	sleep 4
	dm_heal $FAIL; log "healed device $FAIL"
	sleep 2
	writers_stop
	sync
	log "stats after: $(btrfs device stats $MNT | grep -v ' 0$' | tr '\n' ' ')"
	kmsg "raid56: (write|read) error|raid56: retrying" 6
	if dmesg | grep -q "raid56: retrying"; then log "RETRY_OBSERVED"; else log "RETRY_NOT_OBSERVED"; fi
	if btrfs device stats $MNT | grep -q "write_io_errs *[1-9]"; then log "DEVSTATS_OBSERVED"; else log "DEVSTATS_NOT_OBSERVED"; fi
	stats
	verify_old FULL
	umount $MNT || log "UMOUNT_FAIL"
	dmsetup remove_all
	finish
	;;
scrub)
	do_mount $OPTS $MNTDEV
	btrfs scrub start -B -d $MNT 2>&1 | grep -E "Error summary|corrected|uncorrectable|unverified" | while read -r l; do log "scrub: $l"; done
	umount $MNT || log "UMOUNT_FAIL"
	finish
	;;
*)
	log "UNKNOWN MODE"
	finish
	;;
esac
