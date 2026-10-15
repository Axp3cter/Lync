#!/bin/sh
# Reproduces every output in this folder. Usage: sh run.sh LUNE ROJO LUAU WORK_DIR CORPUS_LIST
#   LUNE: Lune 0.11.0; ROJO: Rojo 7.7.1; LUAU: the luau CLI built from .data/projects/luau (0.742);
#   WORK_DIR: scratch (places, corpus module); CORPUS_LIST: one .luau path per line (the run used the 219 files of
#   1-64 KB under .data/projects/{luau/tests,lute,roblox-ts/include,rojo}, of which 217 are UTF-8: 1,648,210 B).
# Fetched third-party files (Knit Comm, Cmdr) are scanned from WORK_DIR/real and never stored here.
set -e
LUNE=$1; ROJO=$2; LUAU=$3; W=$4; LIST=$5
mkdir -p "$W/bench"
"$LUNE" run fixture_place.luau "$W/fixture.rbxl" > /dev/null
"$LUNE" run check.luau "$W/fixture.rbxl" > check_fixture.out
( cd rojo-fixture && "$LUNE" run ../make_rbxm.luau Gear.rbxm && "$ROJO" sourcemap --include-non-scripts default.project.json -o "$W/sm.json" > /dev/null \
  && "$ROJO" build default.project.json -o "$W/rojo.rbxl" > /dev/null && rm Gear.rbxm )
python3 -I -c "
import json,sys
def walk(n,p=''):
    q=p+'.'+n['name'] if p else n['name']
    print(n['className'].ljust(22), q, n.get('filePaths',[]))
    for c in n.get('children',[]): walk(c,q)
walk(json.load(open(sys.argv[1])))" "$W/sm.json" > rojo_sourcemap.out
"$LUNE" run check.luau "$W/rojo.rbxl" >> rojo_sourcemap.out
: > scale.out
for spec in "10000 200" "100000 1000" "500000 3000"; do set -- $spec
  "$LUNE" run scale_place.luau "$W/p$1.rbxl" $1 $2 "$LIST" >> scale.out
  for r in 1 2 3; do taskset -c 3 "$LUNE" run check.luau "$W/p$1.rbxl" quiet >> scale.out; done
done
cp lex.luau scan.luau bench_scan.luau "$W/bench/" && python3 -I corpus_module.py "$LIST" "$W/bench/corpus.luau"
( cd "$W/bench" && for r in 1 2 3; do taskset -c 3 "$LUAU" -O2 bench_scan.luau; done; \
  for r in 1 2 3; do taskset -c 3 "$LUAU" -O2 --codegen bench_scan.luau; done ) > bench_scan.out
taskset -c 3 "$LUNE" run drift.luau ../codecs-in-scripts/woven_Weapon.luau.txt > drift.out
if [ -d "$W/real" ]; then "$LUNE" run scan_files.luau "$W/real/RemoteSignal.luau" "$W/real/CommServer.luau" "$W/real/Cmdr.luau" > real_creation.out; fi
