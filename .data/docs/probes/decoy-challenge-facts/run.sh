#!/bin/sh
# Reproduces the U11/U14 probes. Usage: sh run.sh LUAU_BUILD_DIR ANALYZE_BIN
#   LUAU_BUILD_DIR: a Release build of .data/projects/luau (0.742) holding `luau`
#   ANALYZE_BIN:    luau-analyze 0.740 (the luau skill's pinned toolchain)
set -e
B=$1; A=$2; P=$(dirname "$0")
{
	echo "== interpreted (luau 0.742 -O2)"; "$B/luau" -O2 "$P/cost.luau"
	echo "== native (luau 0.742 -O2 --codegen)"; "$B/luau" -O2 --codegen "$P/cost.luau"
} > "$P/cost.out"
"$B/luau" "$P/lint.luau" > "$P/lint.out"
{
	for s in new old; do
		echo "== types.luau, --solver=$s --mode=strict (expect exactly the errors marked EXPECT)"
		"$A" --solver=$s --mode=strict --formatter=plain "$P/types.luau" 2>&1 || true
	done
} > "$P/types.out"
