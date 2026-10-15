#!/bin/sh
# Reproduces this run's generation-methods probes with Luau 0.742 built from .data/projects/luau.
# Usage: sh run2.sh BUILD_DIR WORK_DIR
set -e
B=$1; W=$2; P=$(dirname "$0"); mkdir -p "$W"
sh "$P/opcodes.sh" "$B" "$W/op" > "$P/opcodes.out"
sh "$P/bytecode2.sh" "$B" "$W/bc" > "$P/bytecode2.out"
for f in offsets dispatch; do
	{ echo "== interpreted (luau 0.742 -O2)"; "$B/luau" -O2 "$P/$f.luau"; echo "== native (--codegen)"; "$B/luau" -O2 --codegen "$P/$f.luau"; } > "$P/$f.out"
done
"$B/luau" -O2 "$P/column_offset.luau" > "$P/column_offset.out"
"$B/luau" -O2 "$P/free_choice.luau" > "$P/free_choice.out"
