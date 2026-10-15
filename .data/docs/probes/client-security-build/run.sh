#!/bin/sh
# Reproduce the probes. Arguments: paths to the tools (versions used: Rojo 7.7.1, Lute 1.0.0, Lune 0.11.0,
# luau/luau-compile 0.740 from the luau skill, Node 22 with smol-toml 1.9.1). OUT is a scratch directory.
# usage: run.sh ROJO LUTE LUNE LUAU_DIR NODE NODE_MODULES OUT
set -e
ROJO=$1 LUTE=$2 LUNE=$3 LUAU=$4 NODE=$5 NM=$6 OUT=$7
HERE=$(cd "$(dirname "$0")" && pwd)
(cd "$HERE/fixture" && "$ROJO" sourcemap default.project.json -o sourcemap.json)
cd "$HERE"
for run in a b; do for seed in 0 7; do "$LUTE" run gen.luau fixture $seed "$OUT/gen$seed$run"; done; done
cmp "$OUT/gen0a/manifest.json" "$OUT/gen0b/manifest.json" && echo "seed 0: two runs byte-identical"
diff -r "$OUT/gen7a" "$OUT/gen7b" && echo "seed 7: two runs byte-identical"
for f in "$OUT"/gen7a/*.gen.luau; do "$LUAU/luau-compile" --null -O2 "$f" && echo "compiles: $(basename "$f")"; done
python3 -I rotation/compare.py "$LUAU/luau-compile" "$LUAU/luau" "$OUT/rot"
python3 -I config/parity.py "$LUAU/luau" "$HERE/../../../projects/lute/batteries/toml.luau" "$NODE" "$NM" "$LUNE" "$OUT/parity" config/lync.toml config/edges.toml
