#!/bin/bash
# Regression suite for the RAID5/6 integrity work.  Unlike the individual
# scenario scripts, this one JUDGES its output and exits non-zero if anything
# regressed, so it can be run before and after a change without a human
# reading every line.
#
#   BTRFS_TEST_DIR=/var/tmp/btrfs-test ./regress.sh [kernel-build-dir]
#
# Default kernel build dir is $BTRFS_TEST_DIR/uml-verify.
set -u
T=${BTRFS_TEST_DIR:?set BTRFS_TEST_DIR to a scratch directory}
BUILD=${1:-$T/uml-verify}
K=$BUILD/linux
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../../.." && pwd)
LOG=$T/regress.$$
mkdir -p $LOG
fails=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fails=$((fails+1)); }
note() { printf '  ....  %s\n' "$1"; }

# --self-check: prove the checking logic actually detects a regression, by
# doctoring a real sweep and confirming each check flags it.  A suite that has
# only ever passed is not evidence of anything.
if [ "${1:-}" = "--self-check" ]; then
	( cd $REPO/tools/testing/btrfs && ./sweep.sh ) > $LOG/sweep 2>&1
	sed 's/^--parity 1 --depth 3  *OK.*/--parity 1 --depth 3   VIOLATION (injected)/' \
		$LOG/sweep > $LOG/sweep.bad1
	sed 's/^--depth 3 --no-missing-faults.*/--depth 3 --no-missing-faults   OK: injected/' \
		$LOG/sweep > $LOG/sweep.bad2
	clean_violations() { grep -E "^--parity" "$1" | grep -v -- "--in-place" |
		grep -v -- "--nodatasum" | grep -c "VIOLATION"; }
	reverts_broken() { sed -n '/reverted must break/,$p' "$1" | grep -E "^--depth" |
		grep -c "VIOLATION"; }
	reverts_total() { sed -n '/reverted must break/,$p' "$1" | grep -cE "^--depth"; }
	[ "$(clean_violations $LOG/sweep)" = 0 ] && pass "real sweep: no should-be-clean violations" \
		|| fail "real sweep already violates -- cannot self-check"
	[ "$(clean_violations $LOG/sweep.bad1)" -gt 0 ] && pass "detects a should-be-clean config that starts violating" \
		|| fail "would NOT detect a should-be-clean config violating"
	[ "$(reverts_broken $LOG/sweep.bad2)" != "$(reverts_total $LOG/sweep.bad2)" ] \
		&& pass "detects a reverted fix that stops breaking anything" \
		|| fail "would NOT detect a reverted fix that stops breaking anything"
	[ $fails -eq 0 ] && { printf '\033[32mSELF-CHECK PASSED\033[0m\n'; exit 0; }
	printf '\033[31mSELF-CHECK FAILED\033[0m\n'; exit 1
fi

# A second run against the same build directory relinks the kernel the first
# one is booting, so both are testing something that no longer exists on disk
# -- and neither says so.  Take the directory for the duration.
mkdir -p $BUILD
exec 9>$BUILD/.regress.lock
if ! flock -n 9; then
	echo "another regress.sh (or a build) holds $BUILD -- wait for it or use a different build dir" >&2
	exit 1
fi

echo "== build =="
# Drop the btrfs objects so the code under test is actually recompiled: make is
# incremental, so without this a repeat run compiles nothing and any check on
# the log passes by seeing an empty file.
rm -f $BUILD/fs/btrfs/*.o $BUILD/fs/btrfs/tests/*.o 2>/dev/null
if make -C $REPO ARCH=um O=$BUILD -j$(nproc) linux > $LOG/build 2>&1; then
	# Compiler diagnostics are indented or preceded by a file:line: prefix and
	# a space, so the pattern must not anchor "warning:" to the line start.
	if grep -qE "(^|[[:space:]])(error|warning):" $LOG/build; then
		fail "build emitted diagnostics"
		grep -E "(^|[[:space:]])(error|warning):" $LOG/build | head -5
	else
		pass "builds fs/btrfs clean from scratch"
	fi
	built=1
else
	fail "build failed"; tail -15 $LOG/build
fi

# Every scenario below boots $K against the btrfs-progs in $T.  Without them
# each one fails for want of a rig, and the suite reports a screenful of
# regressions that are really one missing kernel -- which is exactly how a
# wiped $BTRFS_TEST_DIR reads.  Decide once, here, and say what to do about
# it; the model checker needs neither and runs either way.
rig=1
if [ "${built:-0}" != 1 ]; then
	rig=0
	[ -f $BUILD/.config ] || note "no $BUILD/.config -- run ./setup.sh to recreate the rig"
elif [ ! -x $K ]; then
	rig=0; fail "no kernel at $K -- run ./setup.sh"
elif [ ! -x $T/progs-install/bin/mkfs.btrfs ]; then
	rig=0; fail "no btrfs-progs in $T/progs-install -- run ./setup.sh"
fi

echo "== redundancy model =="
( cd $REPO/tools/testing/btrfs && ./sweep.sh ) > $LOG/sweep 2>&1
# Configurations that must be clean.  --in-place and --nodatasum are the two
# documented residual exposures (see docs/superpowers/needs-direction.md);
# they are expected to violate and are checked separately so that a change in
# their status is not mistaken for a pass.
# Only the default-width block starts with "--parity"; the wider-array block
# starts with "--data" and is judged separately just below.
clean_block() { sed -n '/must be clean everywhere/,/residual exposures/p' $LOG/sweep; }
bad=$(clean_block | grep -E "^--parity" | grep -c "VIOLATION")
[ "$bad" = 0 ] && pass "fixed accounting clean in every configuration" \
	|| { fail "$bad configurations that should be clean now violate"
	     clean_block | grep -E "^--parity" | grep "VIOLATION"; }
# The wider arrays are the open finding of needs-direction.md item 5, so they
# are expected to violate.  Reported both ways round: if they stop violating
# without a kernel change, the model's policy has drifted away from the kernel
# again, which is how the finding got deleted as resolved once already.
wide=$(sed -n '/### wider arrays/,/### de-rate/p' $LOG/sweep | grep -cE "^--data.*VIOLATION")
widetot=$(sed -n '/### wider arrays/,/### de-rate/p' $LOG/sweep | grep -cE "^--data")
[ "$wide" -gt 0 ] && note "$wide/$widetot wider-array configurations violate (open, needs-direction item 5)" \
	|| fail "wider arrays no longer violate -- is that a kernel change, or did the model's default policy drift?"
# The de-rate proposals are the measurement item 5 rests on: the flat variant
# must close the wider-array loss, and must still cost availability.  If either
# stops being true the entry needs rewriting.
derate=$(sed -n '/### de-rate/,/### each accounting/p' $LOG/sweep)
[ "$(echo "$derate" | grep -cE '^--data.*OK:')" = "$(echo "$derate" | grep -cE '^--data')" ] \
	&& pass "both de-rate proposals still close the wider-array loss" \
	|| fail "a de-rate proposal no longer closes the wider-array loss -- update needs-direction.md"
echo "$derate" | grep -q -- "--availability.*VIOLATION (spurious" \
	&& note "the flat de-rate still costs availability (why it is not applied)" \
	|| fail "the flat de-rate no longer costs availability -- reconsider needs-direction item 5"
# The residual exposures are compared against a recorded baseline rather than
# asserted to all violate.  Requiring every row to violate is not a check: a
# row that cannot violate in the configuration the sweep runs it in satisfies
# nothing, and a row that stops violating is progress, not a regression.  A
# diff surfaces both directions -- a new exposure, and one that closed and
# should come out of the docs.
BASE=$REPO/tools/testing/btrfs/uml/residual-exposures.txt
sed -n '/residual exposures/,/wider arrays/p' $LOG/sweep | grep -E "^--parity" |
	sed 's/  */ /g; s/ *$//' | sed 's/\(VIOLATION\).*/\1/; s/\(OK\):.*/\1/' |
	sort > $LOG/residual
if [ ! -f $BASE ]; then
	fail "no residual baseline at $BASE"
elif grep -v '^#' $BASE | diff -u - $LOG/residual > $LOG/residual.diff; then
	note "residual exposures match the recorded baseline"
else
	fail "residual exposures changed -- update $BASE and needs-direction.md"
	cat $LOG/residual.diff
fi
rev=$(sed -n '/reverted must break/,$p' $LOG/sweep | grep -cE "^--depth")
revbad=$(sed -n '/reverted must break/,$p' $LOG/sweep | grep -E "^--depth" | grep -c "VIOLATION")
[ "$rev" -gt 0 ] && [ "$rev" = "$revbad" ] && pass "every reverted accounting fix still breaks something ($rev/$rev)" \
	|| fail "a reverted fix no longer breaks anything ($revbad/$rev)"

if [ $rig != 1 ]; then
	printf '\n\033[31mno rig -- the scenarios below were not run\033[0m\n'
	printf '%d check(s) failed\n' $fails
	exit 1
fi

echo "== scrub pause protocol =="
# Exhaustive over interleavings, so this answers what a timing-based test
# cannot: the two attempts at provoking the wedge by hand both completed, and
# proved nothing either way.
( cd $REPO/tools/testing/btrfs && python3 scrub_pause_model.py --pausers 1 --recovery 1 --quiet ) > $LOG/pause1 2>&1
grep -q "DEADLOCK" $LOG/pause1 \
	&& note "a recovery in the pause protocol deadlocks with a single commit (why the guard exists)" \
	|| fail "the unguarded recovery no longer deadlocks -- has the protocol changed?"
( cd $REPO/tools/testing/btrfs && python3 scrub_pause_model.py --pausers 2 --scrubs 1 --recovery 1 --guard --quiet ) > $LOG/pause2 2>&1
grep -q "no deadlock" $LOG/pause2 \
	&& pass "guarded recovery is deadlock-free in every interleaving" \
	|| { fail "the guarded recovery can deadlock"; cat $LOG/pause2; }
( cd $REPO/tools/testing/btrfs && python3 scrub_pause_model.py --pausers 2 --scrubs 1 --recovery 0 --quiet ) > $LOG/pause3 2>&1
grep -q "no deadlock" $LOG/pause3 \
	&& pass "the protocol itself is sound without a recovery in it" \
	|| { fail "upstream's own pause protocol deadlocks -- check the model"; cat $LOG/pause3; }

echo "== scrub policy on unchecksummed stripes =="
# The upstream policy MUST still destroy committed data here: that is the
# defect the whole series exists for, measured under UML at 8 of 32 blocks.
# A model that stops reproducing it has stopped modelling anything.
( cd $REPO/tools/testing/btrfs && python3 scrub_policy_model.py \
	--data 3 --parity 1 --depth 2 --policy upstream --self-check ) > $LOG/scrubpol1 2>&1
grep -qE "^  DESTROY    [1-9]" $LOG/scrubpol1 \
	&& note "regenerating parity over an unverifiable sector still destroys committed data" \
	|| { fail "the model no longer reproduces the defect it was built for"; tail -5 $LOG/scrubpol1; }

# What the kernel now does, on both sides.  Both must be clean on every axis.
for pol in stale-skip stale-budgeted; do
	for par in 1 2; do
		( cd $REPO/tools/testing/btrfs && python3 scrub_policy_model.py \
			--data 3 --parity $par --depth 2 --policy $pol --persist-stale ) \
			> $LOG/scrubpol.$pol.$par 2>&1
		if grep -qE "^  (MISREPAIR|DESTROY)  *[1-9]" $LOG/scrubpol.$pol.$par; then
			fail "scrub policy $pol destroys or misrepairs at parity $par"
			grep -A 3 -E "^  (MISREPAIR|DESTROY)" $LOG/scrubpol.$pol.$par | head -8
		else
			pass "scrub policy $pol is clean at parity $par"
		fi
	done
done

# The read path.  "stale-any" is the version that shipped and must still be
# shown to regress, or the budgeted rule is being credited for nothing.
( cd $REPO/tools/testing/btrfs && python3 scrub_policy_model.py \
	--data 3 --parity 1 --depth 2 --all-readers ) > $LOG/readers 2>&1
# Only the table rows: the counterexample heading below the table starts
# with the same policy name, and its third field is a word, not a count.
awk '$3 !~ /^[0-9]+$/         { next }
     $1 == "stale-any"        { print "any", $3 }
     $1 == "stale-budgeted"   { print "bud", $3 }' $LOG/readers > $LOG/readers.n
grep -q "^any [1-9]" $LOG/readers.n \
	&& note "acting on the stale record without a budget still regresses reads" \
	|| fail "the unbudgeted reader no longer regresses -- the control is dead"
grep -q "^bud 0$" $LOG/readers.n \
	&& pass "the budgeted reader never returns a value that was not committed" \
	|| { fail "the budgeted reader regresses"; cat $LOG/readers; }

echo "== in-kernel self tests =="
cp -a $HERE/selftest.sh $T/umltest/ 2>/dev/null
timeout 900 $K mem=1G rootfstype=hostfs rootflags=/ rw \
	init=$T/umltest/selftest.sh quiet con=null con0=fd:0,fd:1 > $LOG/selftest 2>&1
# Two separate questions.  The banner is pr_info from the START of the run, so
# it is still there when a test then fails -- greping only for it reported a
# pass for a failing self test.  A failure is test_err(), i.e. pr_err in the
# form "BTRFS: selftest: <file>:<line> <message>".
if grep -aq "raid56 write-intent log tests" $LOG/selftest; then
	pass "write-intent log self tests ran"
else
	fail "write-intent log self tests did not run"
fi
if grep -aqE "BTRFS: selftest: [^ ]+:[0-9]+ " $LOG/selftest; then
	fail "a self test failed"
	grep -aE "BTRFS: selftest: [^ ]+:[0-9]+ " $LOG/selftest | head -5
else
	pass "no self test reported a failure"
fi
grep -aqE "BUG:|KASAN|Oops|WARNING:" $LOG/selftest \
	&& { fail "kernel splat during self tests"; grep -aE "BUG:|KASAN|Oops|WARNING:" $LOG/selftest | head -3; } \
	|| pass "no kernel splat"

check_scenario() { # <tag> <resultfile> <label>
	local tag=$1 f=$2 label=$3
	local d=$T/umltest/$tag

	# Splats land in the per-boot logs, not in the results file: run3.sh
	# writes only "boot ... rc=N" there.  Searching $f for "BUG:" can never
	# match, which is why this used to pass unconditionally.  init-final3.sh
	# does log KERNEL_SPLAT into the results, so check both.
	if grep -aqrE "BUG:|KASAN|Oops|possible circular|hung task|INFO: task" $d 2>/dev/null \
	   || grep -aq "KERNEL_SPLAT" $f; then
		fail "$label: kernel splat"
		grep -ahrE "BUG:|KASAN|Oops|hung task" $d 2>/dev/null | head -2
		return
	fi
	# A boot that was killed rather than finishing invalidates everything
	# after it: the background writers record a file in the manifest as soon
	# as dd returns, so a kill mid-flight leaves the manifest naming files
	# whose data never landed, and the verification below then reports that
	# as corruption.  timeout(1) exits 124.  Say "the setup died" instead of
	# letting it masquerade as lost data.
	if grep -aq "rc=124" $f; then
		fail "$label: a boot timed out -- setup incomplete, verification not meaningful"
		grep -a "rc=124" $f | head -2
		return
	fi

	# The verdict the scenarios actually emit.  verify_manifest() prefixes
	# both lines with the caller's label, so they read
	#     [recover]  FULL_MANIFEST total=48 bad=0
	#     [degraded] DEGRADED_BAD <file> expected <md5> got <md5>
	# An earlier version of this greped for "] BAD " and "VERIFY total=",
	# neither of which any scenario emits, so both corruption checks were
	# dead and a run could report success with files reading back wrong.
	# Match the prefix, not a guess at it.
	if grep -aq "STALE_SECTOR_SILENT_CORRUPTION" $f; then
		fail "$label: committed data read back wrong"
		grep -a "SILENT_CORRUPTION" $f | head -3
		return
	fi
	# _BAD lines are two different findings wearing one name, and calling
	# both "read back wrong" made a documented exposure look like
	# corruption.  Split them by what the read actually did:
	#
	#   wrong data  the read SUCCEEDED and md5sum printed a full hash that
	#               differs from the manifest.  Serious: the filesystem
	#               handed back content nobody asked it to keep.
	#   read failed  md5sum printed nothing, so the read errored.  That is
	#               what a crash followed by a device loss looks like: the
	#               write-intent log records stripe ADDRESSES, not content,
	#               so a stripe whose data is gone cannot be rebuilt and the
	#               kernel says so ("has unrepairable sectors").  See
	#               needs-direction item 1.  Nondeterministic by nature --
	#               it depends on how many sub-stripe writes the crash
	#               caught in flight, measured at 10 and 13 across two runs
	#               of the same kernel -- so failing on the count would make
	#               the suite report a regression at random.
	local nwrong nreadfail
	nwrong=$(grep -aE "^\[.*\] ([A-Z_]*_)?BAD " $f | awk '$NF ~ /^[0-9a-f]{32}$/' | wc -l)
	nreadfail=$(grep -aE "^\[.*\] ([A-Z_]*_)?BAD " $f | awk '$NF !~ /^[0-9a-f]{32}$/' | wc -l)
	if [ "${nwrong:-0}" != 0 ]; then
		fail "$label: $nwrong file(s) read back complete with different content"
		grep -aE "([A-Z_]*_)?BAD " $f | awk '$NF ~ /^[0-9a-f]{32}$/' | head -3
		return
	fi
	[ "${nreadfail:-0}" != 0 ] && \
		note "$label: $nreadfail file(s) unreadable after crash + device loss (expected, needs-direction item 1)"
	local badcount nmanifest
	badcount=$(grep -aoE "MANIFEST total=[0-9]+ bad=[0-9]+" $f | grep -o "bad=[0-9]*" |
		   cut -d= -f2 | awk '{s+=$1} END {print s+0}')
	# Only the scenarios that run background writers build a manifest, so
	# its absence is not a failure -- but it does mean the only content
	# check this scenario made is verify_old() on a single file, which is
	# worth saying rather than leaving to be inferred from a silent zero.
	nmanifest=$(grep -ac "MANIFEST total=" $f)
	[ "${nmanifest:-0}" != 0 ] || note "$label: no manifest (content checked by verify_old only)"
	[ "${badcount:-0}" != 0 ] && { fail "$label: $badcount file(s) verified wrong"; return; }
	for m in MKFS_FAIL UMOUNT_FAIL CHECK_FAIL CRASH_ARM_FAIL DM_CREATE_FAIL \
		 DM_RELOAD_FAIL NOCOW_READ_FAIL REMOUNT_RW_FAIL; do
		grep -aq "$m" $f && { fail "$label: $m"; return; }
	done
	grep -aq "FULL_READ_OK" $f || { fail "$label: committed data did not read back after recovery"; return; }
	local nrec ndeg nfail
	nrec=$(grep -ac "boot recover .*rc=0" $f)
	ndeg=$(grep -ac "DEGRADED_READ_OK" $f)
	nfail=$(grep -ac "MOUNT_FAIL\|REPLAY_FAILED" $f)
	[ "$nrec" -ge 1 ] || { fail "$label: recovery mount did not succeed"; return; }
	[ "$ndeg" -ge 1 ] || { fail "$label: no degraded read succeeded"; return; }
	pass "$label: recovered, $ndeg degraded reads OK"
	[ "$nfail" -gt 0 ] && note "$label: $nfail mount(s) refused -- expected where the metadata profile cannot survive the omission"
	return 0
}

echo "== sysfs toggle under load =="
( cd $HERE && ./misc3.sh $K rg-toggle toggle raid5:raid1 rw 4 ) > $LOG/toggle 2>&1
grep -aq "boot toggle rc=0" $LOG/toggle && pass "toggle completed" || fail "toggle did not complete"
grep -aqE "ENABLE_FAIL|DISABLE_FAIL" $LOG/toggle && fail "sysfs enable/disable reported failure" \
	|| pass "sysfs enable/disable clean"
grep -aq "compat_ro_flags" $LOG/toggle && note "$(grep -a 'super:' $LOG/toggle | tail -1)"

echo "== crash and recovery =="
( cd $HERE && ./run3.sh $K rg-r5 raid5:raid1 rw 1 4 ) > $LOG/r5 2>&1
check_scenario rg-r5 $LOG/r5 "raid5 crash+recovery"
( cd $HERE && ./run3.sh $K rg-r6 raid6:raid1 rw 1 4 ) > $LOG/r6 2>&1
check_scenario rg-r6 $LOG/r6 "raid6 crash+recovery"

echo "== device failing every write =="
( cd $HERE && ./dmfail34.sh $K rg-flakey flakey raid5:raid1 rw 4 2 ) > $LOG/flakey 2>&1
check_scenario rg-flakey $LOG/flakey "raid5 flakey device"

echo
if [ $fails -eq 0 ]; then
	printf '\033[32mALL CHECKS PASSED\033[0m  (logs in %s)\n' $LOG; exit 0
else
	printf '\033[31m%d CHECK(S) FAILED\033[0m  (logs in %s)\n' $fails $LOG; exit 1
fi
