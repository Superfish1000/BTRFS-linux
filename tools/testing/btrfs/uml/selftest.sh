#!/bin/bash
mount -t proc proc /proc 2>/dev/null
echo "SELFTEST_BEGIN"
dmesg | grep -iE "btrfs.*(test|selftest)|BTRFS: selftest" | tail -n 40
dmesg | grep -E "^\[ *[0-9.]+\] (BUG:|WARNING:|KASAN|Oops)" && echo "KERNEL_SPLAT"
echo "SELFTEST_END"
echo o > /proc/sysrq-trigger
sleep 30
