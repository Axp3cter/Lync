#!/bin/sh
# Re-run the security-cost probes. Usage: sh run.sh <luau binary> [probe ...]
# Each Luau probe runs 3 times interpreted (-O2) and 3 times native (-O2 --codegen); output goes to <probe>.out.
# mask_bytes.py needs: python3 -I mask_bytes.py <dir holding zstandard> ../compression > mask_bytes.out
# gen_field_order.py regenerates field_order_gen.luau.
set -e
LUAU="$1"; shift
cd "$(dirname "$0")"
PROBES="${*:-field_order tag_cover downstream_tag id_shuffle per_viewer mask_cpu caller_probe clock_fit canary_scan enum_rotation getfenv_deopt frame_hook}"
for p in $PROBES; do
	: > "$p.out"
	for mode in "-O2" "-O2 --codegen"; do
		for run in 1 2 3; do
			echo "== $p, $(basename "$LUAU") $mode, run $run" >> "$p.out"
			"$LUAU" $mode "$p.luau" >> "$p.out" 2>&1
		done
	done
done
