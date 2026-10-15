#!/bin/sh
# Reproduces the inbound-budget probes with Luau 0.742 built from .data/projects/luau.
# Usage: sh run.sh BUILD_DIR WORK_DIR [probe ...]
#   BUILD_DIR holds the luau binary; WORK_DIR is scratch outside the repo. The milestone build (git f1fbfd7,
#   src/) is exported into WORK_DIR, never into the repo. One patch, to the scratch copy only: inbound.luau's local
#   decodeUp, decodingOf and process are exposed as Inbound._decodeUp/_decodingOf/_process so the decode can be
#   timed apart from the tag (no behaviour change). hsip.luau (the generated tag forms) is copied from
#   probes/security-costs.
# Each probe runs 3 times interpreted (-O2) and 3 times native (-O2 --codegen) into <probe>.out; derive.py then
# reads the .out files and writes derive.out.
set -e
B=$1; W=$2; shift 2
P=$(cd "$(dirname "$0")" && pwd)
REPO=$(git -C "$P" rev-parse --show-toplevel)
mkdir -p "$W"
rm -rf "$W/src"
git -C "$REPO" archive f1fbfd7 src | tar -x -C "$W"
sed -i 's/^return table.freeze(Inbound)$/Inbound._decodeUp = decodeUp\nInbound._decodingOf = decodingOf\nInbound._process = process\nreturn table.freeze(Inbound)/' "$W/src/session/inbound.luau"
grep -q "Inbound._decodeUp = decodeUp" "$W/src/session/inbound.luau"
python3 -I "$P/gen.py" > /dev/null
cp "$P/gen_decoders.luau" "$P/decode_shapes.luau" "$P/tag_frames.luau" "$W/"
cp "$REPO/.data/docs/probes/security-costs/hsip.luau" "$W/"
PROBES="${*:-decode_shapes tag_frames}"
for p in $PROBES; do
	: > "$P/$p.out"
	for run in 1 2 3; do
		echo "== $p, interpreted (luau 0.742 -O2), run $run" >> "$P/$p.out"
		(cd "$W" && "$B/luau" -O2 "$p.luau") >> "$P/$p.out" 2>&1
		echo "== $p, native (luau 0.742 -O2 --codegen), run $run" >> "$P/$p.out"
		(cd "$W" && "$B/luau" -O2 --codegen "$p.luau") >> "$P/$p.out" 2>&1
	done
done
python3 -I "$P/derive.py" > "$P/derive.out"
