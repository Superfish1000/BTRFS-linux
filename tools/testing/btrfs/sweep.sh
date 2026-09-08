#!/bin/bash
# Sweep the RAID56 redundancy model over its configuration space.
run() { printf "%-62s " "$*"; python3 raid56_redundancy_model.py "$@" 2>&1 | grep -E "VIOLATION|OK:" | head -1; }
echo "### fixed accounting must be clean everywhere"
for parity in 1 2; do for depth in 3 4; do
  run --parity $parity --depth $depth
  run --parity $parity --depth $depth --replacing
  run --parity $parity --depth $depth --missing 0
done; done
echo
# The two documented residual exposures (docs/superpowers/needs-direction.md).
# --in-place only shows under --strict: an overwrite that fails destroys the
# data it was overwriting, and outside --strict a failed write is allowed to
# do that.  Run without it, an --in-place row can never violate, so a check
# that expects one to is checking nothing.
echo "### residual exposures (expected to violate)"
for parity in 1 2; do for depth in 3 4; do
  run --parity $parity --depth $depth --in-place --strict
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
# The de-rate is a PROPOSAL for the wider-array loss above, not something the
# kernel does: rbio_max_errors() is the flat profile tolerance and nothing
# consults the log before a write.  Run here to show what each variant would
# buy, so the entry in needs-direction.md rests on a result rather than an
# argument.  See that file for why neither is applied.
echo "### de-rate proposals for the wider-array loss (not implemented)"
for data in 3 4; do
  run --data $data --parity 1 --depth 3 --flat-sticky-derate
  run --data $data --parity 1 --depth 3 --counted-sticky-derate
done
# And the cost: the flat variant refuses writes the array could still serve.
run --parity 1 --depth 3 --availability --flat-sticky-derate
echo
echo "### each accounting fix reverted must break something"
run --depth 3 --no-missing-faults
run --depth 3 --replacing --replace-inflation
run --depth 3 --replacing --target-aliasing --availability
run --depth 4 --policy upstream
run --depth 4 --policy upstream --replacing
