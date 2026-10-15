#!/bin/sh
# Reproduces the refusals-rejudged probes with Luau 0.742 built from .data/projects/luau.
# Usage: sh run.sh BUILD_DIR WORK_DIR
#   BUILD_DIR holds luau and luau-compile; WORK_DIR is scratch (the milestone source is extracted there,
#   never into the repo).
set -e
B=$1; W=$2; P=$(cd "$(dirname "$0")" && pwd); mkdir -p "$W"
REPO=$(git -C "$P" rev-parse --show-toplevel)
rm -rf "$W/m1" && mkdir -p "$W/m1"
git -C "$REPO" archive f1fbfd7 src | tar -x -C "$W/m1"
cp "$P/r31_decode.luau" "$W/m1/"
{ for run in 1 2 3; do
	echo "== interpreted (luau 0.742 -O2), run $run"; (cd "$W/m1" && "$B/luau" -O2 r31_decode.luau)
	echo "== native (--codegen), run $run"; (cd "$W/m1" && "$B/luau" -O2 --codegen r31_decode.luau)
done; } > "$P/r31_decode.out"
for p in r33_intern r34_seal; do
	{ for run in 1 2 3; do
		echo "== interpreted (luau 0.742 -O2), run $run"; (cd "$P" && "$B/luau" -O2 "$p.luau")
		echo "== native (--codegen), run $run"; (cd "$P" && "$B/luau" -O2 --codegen "$p.luau")
	done; } > "$P/$p.out"
done
sh "$P/r10_names.sh" "$B" "$W/r10" > "$P/r10_names.out"
