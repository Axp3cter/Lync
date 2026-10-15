#!/bin/sh
# Reproduces the strings probes. Usage: sh run.sh BUILD_DIR
#   BUILD_DIR holds a luau binary built from .data/projects/luau (0.742). Python model: python3 -B (no caches).
set -e
B=$1; P=$(cd "$(dirname "$0")" && pwd)
{ for run in 1 2 3; do
	echo "== interpreted (luau 0.742 -O2), run $run"; (cd "$P" && "$B/luau" -O2 strings_cost.luau)
	echo "== native (--codegen), run $run"; (cd "$P" && "$B/luau" -O2 --codegen strings_cost.luau)
done; } > "$P/strings_cost.out"
python3 -B "$P/strings_model.py" > "$P/strings_model.out"
(cd "$P" && "$B/luau" golden_strings.luau) > "$P/golden_strings.out"
