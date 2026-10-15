#!/bin/sh
# Review of v5.md §4 at draft 3.6. Usage: run.sh LUAU (0.742). Writes review.out.
L=$1; cd "$(dirname "$0")"
{ echo "== wire.luau"; "$L" -O2 wire.luau; echo "== residual_canon.luau"; "$L" -O2 residual_canon.luau
  for f in "-O2" "-O2 --codegen"; do echo "== perm_search.luau $f"; "$L" $f perm_search.luau; echo "== derive_rounds.luau $f"; "$L" $f derive_rounds.luau; done; } > review.out 2>&1
