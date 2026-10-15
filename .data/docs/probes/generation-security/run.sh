#!/bin/sh
# Reproduces the generation-security probes against Luau 0.742 built from .data/projects/luau.
# Usage: sh run.sh BUILD_DIR WORK_DIR   (BUILD_DIR: cmake build with luau-compile and libLuau.VM.a; WORK_DIR: scratch)
set -e
B=$1; W=$2; P=$(dirname "$0"); L=$P/../../../projects/luau
python3 -I "$P/gen_limits.py" "$W"
for f in locals_199 locals_201 regs_190 regs_260 closures_2000 closures_33000 consts_200 consts_40000; do
  echo "$f: $("$B/luau-compile" --null -O2 "$W/$f.luau" 2>&1 | head -1)"
done > "$P/limits.out"
for f in consts_200 consts_255 consts_256 consts_1000 consts_40000; do
  t=$("$B/luau-compile" --text -O2 "$W/$f.luau")
  echo "$f: FASTCALL2K=$(echo "$t" | grep -c FASTCALL2K) LOADKX=$(echo "$t" | grep -c LOADKX) bytes_g0=$("$B/luau-compile" --binary -O2 -g0 "$W/$f.luau" | wc -c)"
done >> "$P/limits.out"
g++ -O2 -std=c++17 -I"$L/VM/include" "$P/loadcost.cpp" "$B/libLuau.VM.a" -o "$W/loadcost"
for f in consts_200 consts_1000 closures_2000 consts_40000; do for g in 0 1; do
  "$B/luau-compile" --binary -O2 -g$g "$W/$f.luau" > "$W/$f.g$g.bc"; printf "%s -g%s: " $f $g; "$W/loadcost" "$W/$f.g$g.bc" 41
done; done > "$P/loadcost.out"
"$B/luau-compile" --text -O2 --dump-constants "$P/placement.luau" > "$P/placement.out"
