#!/bin/bash
# Sweep the RAID56 redundancy model over its configuration space.
run() { printf "%-62s " "$*"; python3 raid56_redundancy_model.py "$@" 2>&1 | grep -E "VIOLATION|OK:" | head -1; }
echo "### fixed accounting must be clean everywhere"
for parity in 1 2; do for depth in 3 4; do
  run --parity $parity --depth $depth
  run --parity $parity --depth $depth --replacing
  run --parity $parity --depth $depth --in-place
  run --parity $parity --depth $depth --missing 0
  run --parity $parity --depth $depth --nodatasum
done; done
echo
echo "### each accounting fix reverted must break something"
run --depth 3 --no-missing-faults
run --depth 3 --replacing --replace-inflation
run --depth 3 --replacing --target-aliasing --availability
run --depth 4 --policy upstream
run --depth 4 --policy upstream --replacing
