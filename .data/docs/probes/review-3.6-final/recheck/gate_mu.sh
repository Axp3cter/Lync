#!/bin/sh
# Runs probes/inbound-bound-2/gate.luau (bound "new": v5.md §7.5's prices and mu 0.10) N times, one after another.
# Usage: sh gate_mu.sh LUAU_BIN WORK_DIR N OUT
#   WORK_DIR is a work directory set up by probes/inbound-bound-2/run.sh (steps setup, build, gen); this script copies
#   the repo's gate.luau into it first, so the run uses the edited price table.
set -u
B=$1; W=$2; N=$3; OUT=$4
P=$(cd "$(dirname "$0")/../../inbound-bound-2" && pwd)
cp "$P/gate.luau" "$W/gate.luau"
: > "$OUT"
i=1
while [ "$i" -le "$N" ]; do
	echo "== gate run $i, bound new, native (luau 0.742 -O2 --codegen), $(date -u +%H:%M:%S)" >> "$OUT"
	if (cd "$W" && "$B" -O2 --codegen gate.luau -a new >> "$OUT" 2>&1); then echo "exit 0" >> "$OUT"; else echo "exit $?" >> "$OUT"; fi
	i=$((i + 1))
done
