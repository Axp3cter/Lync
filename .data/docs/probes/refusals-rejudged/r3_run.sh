#!/bin/sh
# Usage: sh r3_run.sh <luau 0.742 binary>. r3_origin: 3 runs interpreted and 3 native into r3_origin.out;
# r3_limit and r3_tagwidth are deterministic: one run each into their .out files.
set -e
LUAU="$1"
cd "$(dirname "$0")"
: > r3_origin.out
for mode in "-O2" "-O2 --codegen"; do
	for run in 1 2 3; do
		echo "== r3_origin, luau 0.742 $mode, run $run" >> r3_origin.out
		"$LUAU" $mode r3_origin.luau >> r3_origin.out 2>&1
	done
done
for p in r3_limit r3_tagwidth; do
	{ echo "== $p, luau 0.742 -O2 (deterministic; one run)"; "$LUAU" -O2 "$p.luau"; } > "$p.out" 2>&1
done
