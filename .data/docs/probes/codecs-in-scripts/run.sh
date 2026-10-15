#!/bin/sh
# Reproduces every output in this folder. Usage: sh run.sh LUAU_SRC BUILD_DIR WORK_DIR LUAU_AST ROJO LUNE
#   LUAU_SRC: a Luau source tree (.data/projects/luau, 0.742); BUILD_DIR: its CMake build (Luau.Repl.CLI,
#   Luau.Compile.CLI, Luau.VM, Luau.Compiler, Luau.CodeGen targets); LUAU_AST: luau-ast 0.740 (luau skill cache).
set -e
LU=$1; B=$2; W=$3; AST=$4; ROJO=$5; LUNE=$6
mkdir -p "$W"
g++ -O2 -std=c++17 host.cpp -I$LU/VM/include -I$LU/Compiler/include -I$LU/CodeGen/include -I$LU/Common/include \
  -Wl,--start-group $B/libLuau.CodeGen.a $B/libLuau.VM.a $B/libLuau.Compiler.a $B/libLuau.Bytecode.a $B/libLuau.Ast.a \
  $B/libLuau.Common.a -Wl,--end-group -o "$W/host"
python3 -I gen.py "$W/gen"
for r in 1 2 3; do sh bench.sh "$W/host" "$W/gen" 3; done > bench.out
python3 -I summarize.py bench.out > bench.md
python3 -I ../client-security-build/placement/size.py "$B/luau-compile" "$W/size_orig" > size_orig.out
python3 -I size.py "$B/luau-compile" "$W/size" > size.out
"$ROJO" build fixture/default.project.json -o "$W/fixture.rbxl"
"$LUNE" run place_io.luau dump "$W/fixture.rbxl" "$W/fixture.json"
python3 -I weave.py "$AST" "$W/fixture.json" "$W/woven.json" weave_report.json ReplicatedStorage.Shared.Net.client
"$LUNE" run place_io.luau apply "$W/fixture.rbxl" "$W/woven.json" "$W/woven.rbxl"
python3 -I -c "import json; [open('$W/weapon_'+n+'.luau','w').write(x['source']) for n,f in (('orig','$W/fixture.json'),('woven','$W/woven.json')) for x in json.load(open(f)) if x['path'].endswith('Weapon')]"
for v in orig woven; do for O in 1 2; do LUAU_O=$O "$W/host" run RT="$W/gen/rt.luau:interp" Net="$W/gen/shard.luau:interp" diff_mock.luau:interp W="$W/weapon_$v.luau:interp" diff_drive.luau:interp; done; done > diff.out
python3 -I buildtime.py "$W/fixture.json" 300 "$W/big.json"
python3 -I weave.py "$AST" "$W/big.json" "$W/bigw.json" "$W/bigr.json" ReplicatedStorage.Shared.Net.client > /dev/null
for o in 1 2; do luau -O$o error_lines.luau; done > error_lines.out
for f in "$W/weapon_orig.luau" "$W/weapon_woven.luau"; do taskset -c 3 "$W/host" load "$f" 20000; done > load.out
