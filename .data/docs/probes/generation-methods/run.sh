#!/bin/sh
# Reproduces the generation-methods probes with Luau 0.742 built from .data/projects/luau.
# Usage: sh run.sh BUILD_DIR WORK_DIR
set -e
B=$1; W=$2; P=$(dirname "$0"); mkdir -p "$W"
{ echo "== interpreted (luau 0.742 -O2)"; "$B/luau" -O2 "$P/shapes.luau"; echo "== native (--codegen)"; "$B/luau" -O2 --codegen "$P/shapes.luau"; } > "$P/shapes.out"
"$B/luau" -O2 "$P/enum_rotation.luau" > "$P/enum_rotation.out"
python3 -I "$P/gen_defs.py" "$W"
for n in 1 50 200; do echo "defs_$n: $("$B/luau-compile" --binary -O2 -g0 "$W/defs_$n.luau" | wc -c) B bytecode -g0, $(wc -c < "$W/defs_$n.luau") B source"; done > "$P/bytecode.out"
