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

echo "== build =="
if make -C $REPO ARCH=um O=$BUILD -j$(nproc) linux > $LOG/build 2>&1; then
	if grep -qE "^[^ ]*(error|warning):" $LOG/build; then
		fail "build emitted diagnostics"; grep -E "(error|warning):" $LOG/build | head -5
	else
		pass "builds clean"
	fi
else
	fail "build failed"; tail -15 $LOG/build
fi

echo "== redundancy model =="
( cd $REPO/tools/testing/btrfs && ./sweep.sh ) > $LOG/sweep 2>&1
# Configurations that must be clean.  --in-place and --nodatasum are the two
# documented residual exposures (see docs/superpowers/needs-direction.md);
# they are expected to violate and are checked separately so that a change in
# their status is not mistaken for a pass.
bad=$(grep -E "^--parity" $LOG/sweep | grep -v -- "--in-place" | grep -v -- "--nodatasum" | grep -c "VIOLATION")
[ "$bad" = 0 ] && pass "fixed accounting clean in every configuration" \
	|| { fail "$bad configurations that should be clean now violate"
	     grep -E "^--parity" $LOG/sweep | grep -v -- "--in-place" | grep -v -- "--nodatasum" | grep "VIOLATION"; }
known=$(grep -E "^--parity" $LOG/sweep | grep -E -- "--in-place|--nodatasum" | grep -c "VIOLATION")
exp=$(grep -E "^--parity" $LOG/sweep | grep -cE -- "--in-place|--nodatasum")
[ "$known" = "$exp" ] && note "$known/$exp known residual exposures still reported (expected)" \
	|| fail "residual exposures changed: $known of $exp still violate"
rev=$(sed -n '/reverted must break/,$p' $LOG/sweep | grep -cE "^--depth")
revbad=$(sed -n '/reverted must break/,$p' $LOG/sweep | grep -E "^--depth" | grep -c "VIOLATION")
[ "$rev" -gt 0 ] && [ "$rev" = "$revbad" ] && pass "every reverted accounting fix still breaks something ($rev/$rev)" \
	|| fail "a reverted fix no longer breaks anything ($revbad/$rev)"

echo "== in-kernel self tests =="
cp -a $HERE/selftest.sh $T/umltest/ 2>/dev/null
timeout 900 $K mem=1G rootfstype=hostfs rootflags=/ rw \
	init=$T/umltest/selftest.sh quiet con=null con0=fd:0,fd:1 > $LOG/selftest 2>&1
grep -aq "raid56 write-intent log tests" $LOG/selftest \
	&& pass "write-intent log self tests ran" || fail "write-intent log self tests did not run"
grep -aqE "BUG:|KASAN|Oops|WARNING:" $LOG/selftest \
	&& { fail "kernel splat during self tests"; grep -aE "BUG:|KASAN|Oops|WARNING:" $LOG/selftest | head -3; } \
	|| pass "no kernel splat"

check_scenario() { # <tag> <resultfile> <label>
	local tag=$1 f=$2 label=$3
	grep -aqE "BUG:|KASAN|Oops|possible circular|hung task" $f \
		&& { fail "$label: kernel splat"; return; }
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
