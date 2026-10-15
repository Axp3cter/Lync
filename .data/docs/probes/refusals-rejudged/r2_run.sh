#!/bin/sh
# Usage: sh r2_run.sh <luau 0.742 binary>. Runs r2_costs.luau 3 times interpreted and 3 times native into r2_costs.out.
set -e
LUAU="$1"
cd "$(dirname "$0")"
: > r2_costs.out
for mode in "-O2" "-O2 --codegen"; do
	for run in 1 2 3; do
		echo "== r2_costs, luau 0.742 $mode, run $run" >> r2_costs.out
		"$LUAU" $mode r2_costs.luau >> r2_costs.out 2>&1
	done
done
