#!/bin/sh
# Reproduces the M13 and M14 probes with Luau 0.742 built from .data/projects/luau.
# Exports Lync's milestone build (git f1fbfd7, src/) into WORK_DIR, never into the repo; srco/ is the same tree
# with patch_rows.py's offset branches in codec/rows.luau.
# Usage: sh run3.sh BUILD_DIR WORK_DIR
set -e
B=$1; W=$2; P=$(cd "$(dirname "$0")" && pwd); mkdir -p "$W"
rm -rf "$W/src" "$W/srco"
R=$(git -C "$P" rev-parse --show-toplevel)
git -C "$R" archive f1fbfd7 src | tar -x -C "$W"
cp -r "$W/src" "$W/srco"
python3 -I "$P/patch_rows.py" "$W/src/codec/rows.luau" "$W/srco/codec/rows.luau"
for f in runtime_path tagbind; do
	cp "$P/$f.luau" "$W/$f.luau"
	( cd "$W" && { echo "== interpreted (luau 0.742 -O2)"; "$B/luau" -O2 "$f.luau"; echo "== native (--codegen)"; "$B/luau" -O2 --codegen "$f.luau"; } ) > "$P/$f.out"
done
