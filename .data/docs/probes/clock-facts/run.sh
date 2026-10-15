#!/bin/sh
# Re-run the clock-facts probes. Usage: sh run.sh <luau 0.742 binary> [<luau-analyze>]
# Cost probes: 3 runs interpreted (-O2) and 3 native (-O2 --codegen) each. Simulations: one seeded run (-O2).
# Type checks: result_types.luau under both solvers (luau-analyze), result_types_ts.ts with tsc --strict.
set -e
LUAU="$1"; ANALYZE="${2:-}"
cd "$(dirname "$0")"
for p in cost beacon_cost; do
	: > "$p.out"
	for mode in "-O2" "-O2 --codegen"; do
		for run in 1 2 3; do
			echo "== $p, luau 0.742 $mode, run $run" >> "$p.out"
			"$LUAU" $mode "$p.luau" >> "$p.out" 2>&1
		done
	done
done
for p in common_mode_sim beacon_sim roundtrip_sim step_response; do
	"$LUAU" -O2 "$p.luau" > "$p.out" 2>&1
done
if [ -n "$ANALYZE" ]; then
	: > result_types.out
	for s in new old; do
		echo "== luau-analyze --solver=$s" >> result_types.out
		"$ANALYZE" --solver=$s result_types.luau >> result_types.out 2>&1 && echo clean >> result_types.out
	done
	echo "== tsc --strict" >> result_types.out
	tsc --ignoreConfig --noEmit --strict result_types_ts.ts >> result_types.out 2>&1 && echo clean >> result_types.out
fi
