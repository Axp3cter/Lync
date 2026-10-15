#!/bin/sh
# Reproduces the r4_ probes (research/refusals-rejudged-4.md) with Luau 0.742 built from .data/projects/luau.
# Usage: sh r4_run.sh BUILD_DIR   (BUILD_DIR holds luau and luau-compile)
set -e
B=$1; P=$(cd "$(dirname "$0")" && pwd); cd "$P"
{ echo "# Luau 0.742 (.data/projects/luau, scratch build), -O2; model output is deterministic (seed 42)"; "$B/luau" -O2 r4_decoy_slots.luau; } > r4_decoy_slots.out
{ echo "# Luau 0.742 (.data/projects/luau, scratch build), Xeon 2.1 GHz shared; best of 7 per line"
  for r in 1 2 3; do echo "== interpreted -O2 run $r"; "$B/luau" -O2 r4_selfcheck.luau
    echo "== native -O2 --codegen run $r"; "$B/luau" -O2 --codegen r4_selfcheck.luau; done
  for o in -O0 -O1; do echo "== $o (debug.info stability)"; "$B/luau" $o r4_selfcheck.luau | head -3; done
  echo "== bytecode -O2 (checkField, checkInfo)"
  "$B/luau-compile" --text -O2 r4_selfcheck.luau 2>&1 | awk '/^Function .*checkField|^Function .*checkInfo/{p=1} /^$/{p=0} p' | grep -v "^R[0-9]"
} > r4_selfcheck.out 2>&1
{ echo "# Luau 0.742 (.data/projects/luau, scratch build), Xeon 2.1 GHz shared"
  for r in 1 2 3; do echo "== native -O2 --codegen run $r"; "$B/luau" -O2 --codegen r4_maxrate.luau
    echo "== interpreted -O2 run $r"; "$B/luau" -O2 r4_maxrate.luau; done; } > r4_maxrate.out 2>&1
{ echo "# Luau 0.742 (.data/projects/luau, scratch build); interpreted -O2, then the last two lines native --codegen"
  "$B/luau" -O2 r4_cooldown.luau; "$B/luau" -O2 --codegen r4_cooldown.luau | tail -2; } > r4_cooldown.out
