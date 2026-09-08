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
# Realistic array widths.  Everything above runs at the default --data 2, i.e.
# a 3-disk RAID5 and a 4-disk RAID6, which is NOT what the measured arrays look
# like (nr_data 3 and 7).  At three or more data stripes the model reports
# acknowledged loss; see docs/superpowers/needs-direction.md.  Listed
# separately so the result is visible rather than absent.
echo "### wider arrays"
for data in 3 4 5; do for parity in 1 2; do
  run --data $data --parity $parity --depth 3
done; done
echo
# Reverting the de-rate must reintroduce the loss it was added to prevent.
echo "### sticky de-rate reverted must break something"
run --data 3 --parity 1 --depth 3 --no-sticky-derate
run --data 4 --parity 1 --depth 3 --no-sticky-derate
echo
echo "### each accounting fix reverted must break something"
# --no-sticky-derate as well: the de-rate computes the stripe's true remaining
# margin, which subsumes the cruder "a missing device faults the whole vertical
# stripe" rule.  With the de-rate on, reverting missing_faults alone no longer
# breaks anything, so the check has to isolate the two or it proves nothing.
run --depth 3 --no-missing-faults --no-sticky-derate
run --depth 3 --replacing --replace-inflation
run --depth 3 --replacing --target-aliasing --availability
run --depth 4 --policy upstream
run --depth 4 --policy upstream --replacing
